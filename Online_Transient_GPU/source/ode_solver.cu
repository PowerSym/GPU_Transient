#include "ode_solver.cuh"
#include <trans_cuda.hpp>
#include <transient.hpp>
#include <map>
#include <iostream>
#include <cmath>
#include <utility>


#include <thrust/device_vector.h>
#include <thrust/for_each.h>
#include <thrust/execution_policy.h>
#include <thrust/reduce.h>
#include <thrust/functional.h>
#include <thrust/iterator/zip_iterator.h>

#include <boost/numeric/odeint.hpp>

#include <boost/numeric/odeint/external/thrust/thrust.hpp>

#include <boost/random/mersenne_twister.hpp>
#include <boost/random/uniform_real.hpp>
#include <boost/random/variate_generator.hpp>


using namespace boost::numeric::odeint;
namespace transient_analysis {

  //std::vector<thrust::device_vector<double>> Vm(8);
  //std::vector<thrust::device_vector<double>> Vx;

real__t ODE_solver::
apply_limiting(real__t val, const real__t val_min, const real__t val_max) {
   //cout << "In apply_limiting .x="  << endl;
  return (val < val_min) ? val_min : ((val > val_max) ? val_max : val);
}

real__t ODE_solver::apply_dead_band(const real__t val, const real__t tol) {
   //cout << "In apply_dead_band .x="  << endl;
  return (abs(val) <= tol) ? 0 : val;
}

/**  integrate_block integrates one step of the following ODE:
 *    (a + bs) / (c + ds) x = y
*/
void ODE_solver::
integrate_block(const vector_type& x, vector_type& dxdt, int idx_src, int idx_dst,
                real__t a, real__t b, real__t c, real__t d) {
   //cout << "In integrate_block 1.x="  << endl;
  dxdt[idx_dst] = (abs(d) < EPS) ? 0 : (a * x[idx_src] + b * dxdt[idx_src] - c * x[idx_dst]) / d;
}

/**  integrate_block integrates one step of the following ODE:
 *    a / (c + ds) x = y
*/
void ODE_solver::
integrate_block(vector_type& dxdt, real__t val_src, real__t val_dst, int idx_dst,
                real__t a, real__t c, real__t d) {
   //cout << "In integrate_block 2.x="  << endl;
  dxdt[idx_dst] = (abs(d) < EPS) ? 0 : (a * val_src - c * val_dst) / d;
}

/**  integrate_block integrates one step of the following ODE:
 *    (a + bs) / (c + ds) x = y,
 * and directly takes the values of x and dx_dt as inputs.
*/

void ODE_solver::
integrate_block(const vector_type& x, vector_type& dxdt, real__t val_src, real__t div_src,
                real__t val_dst, int idx_dst, real__t a, real__t b, real__t c, real__t d) {
  //cout << "In integrate_block 3.x="  << endl;
  dxdt[idx_dst] = (abs(d) < EPS) ? 0 : (a * val_src + b * div_src - c * val_dst) / d;
}

/**  process_PID_block does two things:
 * 1. calculate the output value
 * 2. process the ODE:    s y = Ki * x
*/
real__t ODE_solver::
process_PID_block(const vector_type& x, vector_type& dxdt, real__t val_src, real__t div_src,
                  int idx_pid, PID_DATA &pid) {
  //cout << "In process_PID_block x="  << endl;
  real__t val1 = pid.Kp * val_src;
  real__t val2 = pid.Kd * div_src;
  dxdt[idx_pid] = pid.Ki * val_src;
  real__t val3 = apply_limiting(x[idx_pid], 10. * pid.I_Min, 10. * pid.I_Max);
  real__t val_total = val1 + val2 + val3;
  return apply_limiting(val_total, 10. * pid.PID_Min, 10. * pid.PID_Max);
}

/** a helper function for debugging */
void ODE_solver::print_dxdt(const vector_type& dxdt) {
  //cout << "In print_dx_dt" << endl;
  TextTable t('-', '|', '+');

  t.addRow(vector<string>{"omega", "delta", "Eqp", "Edp", "Eqpp", "Edpp", "delta_mu"});

  t.add(to_string(dxdt[omega_idx]));
  t.add(to_string(dxdt[delta_idx]));
  t.add(to_string(dxdt[Eqp_idx]));
  t.add(to_string(dxdt[Edp_idx]));
  t.add(to_string(dxdt[Eqpp_idx]));
  t.add(to_string(dxdt[Edpp_idx]));
  t.add(to_string(dxdt[delta_mu_idx]));
  t.endOfRow();

  std::cout << t;
}

void ODE_solver::update_generator_current(const d_vector_type& x, EPRI_GEN_DATA& gen) {
  //if (parameters.GEN_type == 3 || parameters.GEN_type == 6) {
  //  real__t denom = gen.Ra * gen.Ra + gen.Xdpp * gen.Xqpp;
  //  //assert(denom > EPS);
  //  Id = (+gen.Ra * (x[Edpp_idx] - Vd) + gen.Xqpp * (x[Eqpp_idx] - Vq)) / denom;
  //  Iq = (-gen.Xdpp * (x[Edpp_idx] - Vd) + gen.Ra * (x[Eqpp_idx] - Vq)) / denom;
  //} else {
   /*
    real__t denom = gen.Ra * gen.Ra + gen.Xdp * gen.Xqp;
    //assert(abs(denom) > EPS);
    Id = (+gen.Ra * (x[Edp_idx] - Vd) + gen.Xqp * (x[Eqp_idx] - Vq)) / denom;
    Iq = (-gen.Xdp * (x[Edp_idx] - Vd) + gen.Ra * (x[Eqp_idx] - Vq)) / denom;
     */
  //}
}


struct parallel_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double Vx = thrust::get<0>(t);
     double Vy = thrust::get<1>(t);
     double x_omega_idx = thrust::get<2>(t);
     double x_delta_id = thrust::get<3>(t);
     double x_Eqp_idx = thrust::get<4>(t);
     double gen_a = thrust::get<5>(t);
     double gen_b = thrust::get<6>(t);
     double gen_n = thrust::get<7>(t);
     double gen_Ra = thrust::get<8>(t);
     double dxdt_Eqp_idx = thrust::get<9>(t);
     //solver.Vm = sqrt(solver.Vx *solver.Vx + solver.Vy * solver.Vy);
     double Vm = sqrt(thrust::get<0>(t) * thrust::get<0>(t) + thrust::get<1>(t) * thrust::get<1>(t));
     //Va = atan2(Vy, Vx);
     double Va = atan2(thrust::get<1>(t), thrust::get<0>(t));
     //Vd = Vm * sin(x[delta_idx] - Va);
     double Vd = Vm * sin(x_delta_id -  Va);
     //Vq = Vm * cos(x[delta_idx] - Va);
     double Vq = Vm  * cos(x_delta_id -  Va);
     //Ifd     = gen.a * x[Eqp_idx] + gen.b * pow(x[Eqp_idx], gen.n);
     double Ifd = gen_a * x_Eqp_idx + gen_b * pow(x_Eqp_idx, gen_n);
     //dIfd_dt = gen.a * dxdt[Eqp_idx] + gen.b * gen.n * pow(x[Eqp_idx], gen.n - 1) * dxdt[Eqp_idx];
     double dIfd_dt = gen_a * dxdt_Eqp_idx + gen_b * gen_n * pow(x_Eqp_idx, gen_n -1) * x_Eqp_idx;
     //printf("threadidx.x=%d\n", threadIdx.x);
     //printf("threadidx.y=%d\n", threadIdx.y);
     //printf("blockidx.x=%d\n", blockIdx.x);
     //printf("blockidx.y=%d\n", blockIdx.y);

     //update_generator_current(x, gen);
     //real__t denom = gen_Ra * gen_Ra + gen.Xdp * gen.Xqp;
     //assert(abs(denom) > EPS);
     //Id = (+gen.Ra * (x[Edp_idx] - Vd) + gen.Xqp * (x[Eqp_idx] - Vq)) / denom;
     //Iq = (-gen.Xdp * (x[Edp_idx] - Vd) + gen.Ra * (x[Eqp_idx] - Vq)) / denom;

     //real__t Psi_q = -(gen.Ra * Id + Vd) / x[omega_idx];
     //real__t Psi_d = +(gen.Ra * Iq + Vq) / x[omega_idx];

     //Telec = Psi_d * Iq - Psi_q * Id;

     //for(value_type v: dxdt)  {v = 0;}

     
     //for(int i = 0; i < 8*35; i++){
     //    printf("i=%d\n", i);
     //    printf("x=%d\n",thrust::get<5>(t));
     //   std::cout<<"thrust::get<5>(t)" << "="<< thrust::get<5>(t) << std::endl;
     //   std::cout<<"x[delta_idx]" << "="<< x[delta_idx] << std::endl;
    //}

     
   }
};


struct update_generator_current_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double gen_Ra = thrust::get<0>(t);
     double gen_Xdp = thrust::get<1>(t);
     double gen_Xqp = thrust::get<2>(t);
     double x_Edp_idx = thrust::get<3>(t);
     double x_Eqp_idx = thrust::get<4>(t);
     double Vd = thrust::get<5>(t);
     double Vq = thrust::get<6>(t);
     double x_omega_idx = thrust::get<7>(t);
     double Id = thrust::get<8>(t);
     double Iq = thrust::get<9>(t);

     //update_generator_current(x, gen);
     double  denom = gen_Ra * gen_Ra + gen_Xdp * gen_Xqp;
     //assert(abs(denom) > EPS);
     thrust::get<8>(t) = (+gen_Ra * (x_Edp_idx - Vd) + gen_Xqp * (x_Eqp_idx - Vq)) / denom;
     thrust::get<8>(t) = (-gen_Xdp * (x_Edp_idx - Vd) + gen_Ra * (x_Eqp_idx - Vq)) / denom;

   }
};
//void ODE_solver::setup(const d_vector_type& x, d_vector_type& dxdt) {
void ODE_solver::setup(const d_vector_type& x, d_vector_type& dxdt, EPRI_GEN_DATA& gen) {
  
  //Vm = sqrt(Vx *Vx + Vy * Vy);
  //Va = atan2(Vy, Vx);
  //Vd = Vm * sin(x[delta_idx] - Va);
  //Vq = Vm * cos(x[delta_idx] - Va);
  
  //Ifd     = gen.a * x[Eqp_idx] + gen.b * pow(x[Eqp_idx], gen.n);
  //dIfd_dt = gen.a * dxdt[Eqp_idx] + gen.b * gen.n * pow(x[Eqp_idx], gen.n - 1) * dxdt[Eqp_idx];
  
  //update_generator_current(x, gen);

  //real__t Psi_q = -(gen.Ra * Id + Vd) / x[omega_idx];
  //real__t Psi_d = +(gen.Ra * Iq + Vq) / x[omega_idx];

  //Telec = Psi_d * Iq - Psi_q * Id;
  
  for(value_type v: dxdt)  {v = 0;}
}

struct parallel_setup_1_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double Vm = thrust::get<0>(t);
     double Vx = thrust::get<1>(t);
     double Vy = thrust::get<2>(t);
     double Va = thrust::get<3>(t);
     double Vd = thrust::get<4>(t);
     double Vq = thrust::get<5>(t);
     double x_delta_id = thrust::get<6>(t);
     //solver.Vm = sqrt(solver.Vx *solver.Vx + solver.Vy * solver.Vy);
     thrust::get<0>(t) = sqrt(thrust::get<1>(t) * thrust::get<1>(t) + thrust::get<2>(t) * thrust::get<2>(t));
     //Va = atan2(Vy, Vx);
     thrust::get<3>(t) = atan2(thrust::get<2>(t), thrust::get<1>(t));
     //Vd = Vm * sin(x[delta_idx] - Va);
     thrust::get<4>(t) = thrust::get<0>(t) * sin(x_delta_id -  thrust::get<3>(t));
     //Vq = Vm * cos(x[delta_idx] - Va);
     thrust::get<5>(t) = thrust::get<0>(t)  * cos(x_delta_id -  thrust::get<3>(t));

   }
};


struct parallel_setup_2_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double Ifd = thrust::get<0>(t);
     double gen_a = thrust::get<1>(t);
     double x_Eqp_idx = thrust::get<2>(t);
     double gen_b = thrust::get<3>(t);
     double gen_n = thrust::get<4>(t);
     double dIfd_dt = thrust::get<5>(t);
     double dxdt_Eqp_idx = thrust::get<6>(t);
     //Ifd     = gen.a * x[Eqp_idx] + gen.b * pow(x[Eqp_idx], gen.n);
     thrust::get<0>(t) = gen_a * x_Eqp_idx + gen_b * pow(x_Eqp_idx, gen_n);
     //dIfd_dt = gen.a * dxdt[Eqp_idx] + gen.b * gen.n * pow(x[Eqp_idx], gen.n - 1) * dxdt[Eqp_idx];
     thrust::get<5>(t) = gen_a * dxdt_Eqp_idx + gen_b * gen_n * pow(x_Eqp_idx, gen_n -1) * x_Eqp_idx;

   }
};



struct parallel_setup_3_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double gen_Ra = thrust::get<0>(t);
     double Id = thrust::get<1>(t);
     double Vd = thrust::get<2>(t);
     double x_omega_idx = thrust::get<3>(t);
     double Iq = thrust::get<4>(t);
     double Vq = thrust::get<5>(t);
     double Telec = thrust::get<6>(t);
     //real__t Psi_q = -(gen_Ra * Id + Vd) / x_omega_idx;
     //real__t Psi_d = +(gen_Ra * Iq + Vq) / x_omega_idx;

     //Telec = Psi_d * Iq - Psi_q * Id;
     double Psi_q = -(gen_Ra * Id + Vd) / x_omega_idx;
     double Psi_d = +(gen_Ra * Iq + Vq) / x_omega_idx;
     thrust::get<6>(t) = Psi_d * Iq - Psi_q * Id;

   }
};



struct apply_perturbation_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double t_d = thrust::get<0>(t);
     double gen_bus_id = thrust::get<1>(t);
     double Vm_ref = thrust::get<2>(t);
     double parameters_Vt_ref = thrust::get<3>(t);
     double omega_ref = thrust::get<4>(t);
     double parameters_omega_ref = thrust::get<5>(t);

     if (t_d >= 10 && t_d <= 15 && (gen_bus_id == 0)) {
        thrust::get<2>(t) = parameters_Vt_ref * 1.0;
     } else {
        thrust::get<2>(t) = parameters_Vt_ref;
     }

     if (t_d >= 5 && t_d <= 20 && (gen_bus_id == 2 || gen_bus_id == 3)) {
        thrust::get<4>(t) = parameters_omega_ref * 1.0;
     } else {
        thrust::get<4>(t) = parameters_omega_ref;
     }

   }
};


struct process_EPRI_GEN_TYPE_I_D_functor
{
   template<typename Tuple>
   __device__
   void operator()(Tuple t) const
   {
     double x_omega_idx = thrust::get<0>(t);
     double d_omega_ref = thrust::get<1>(t);
     double d_dxdt_omega_idx = thrust::get<2>(t);
     double d_TJ = thrust::get<3>(t);
     double d_EPS = thrust::get<4>(t);
     double d_Pmech = thrust::get<5>(t);
     double d_Telec = thrust::get<6>(t);
     double d_D = thrust::get<7>(t);
     double d_dxdt_delta_idx = thrust::get<8>(t);
     double d_freq_ref = thrust::get<9>(t);

     double d_omega_diff = x_omega_idx - d_omega_ref;
     //double PI = 3.141592653589793;
     thrust::get<2>(t) = (d_TJ < d_EPS)
                    ? 0
                    : (d_Pmech - d_Telec - d_D * d_omega_diff) / d_TJ;

     thrust::get<8>(t) = 2 * 3.141592653589793 * d_freq_ref * d_omega_diff;

   }
};

void ODE_solver::
operator()(const d_vector_type &x, d_vector_type &dxdt, const value_type t) {
  //setup(x, dxdt, d_parameters.gen);
  thrust::device_vector<double> d_Vm(8);
  thrust::device_vector<double> d_Vx(8);
  thrust::device_vector<double> d_Vy(8);
  thrust::device_vector<double> d_Va(8);
  thrust::device_vector<double> d_Vd(8);
  thrust::device_vector<double> d_Vq(8);
  thrust::device_vector<double> d_Ifd(8);
  thrust::device_vector<double> d_x_omega_idx(8);
  thrust::device_vector<double> d_x_delta_id(8);
  thrust::device_vector<double> d_x_Eqp_idx(8);
  thrust::device_vector<double> d_gen_a(8);
  thrust::device_vector<double> d_gen_b(8);
  thrust::device_vector<double> d_gen_n(8);
  thrust::device_vector<double> d_gen_Ra(8);
  thrust::device_vector<double> d_dxdt_Eqp_idx(8);
  thrust::device_vector<double> d_gen_Xdp(8);
  thrust::device_vector<double> d_gen_Xqp(8);
  thrust::device_vector<double> d_x_Edp_idx(8);
  thrust::device_vector<double> d_dIfd_dt(8);
  thrust::device_vector<double> d_Id(8);
  thrust::device_vector<double> d_Iq(8);
  thrust::device_vector<double> d_Telec(8);
  thrust::device_vector<int> d_gen_bus_id(8);
  thrust::device_vector<double> d_Vm_ref(8);
  thrust::device_vector<double> d_parameters_Vt_ref(8);
  thrust::device_vector<double> d_omega_ref(8);
  thrust::device_vector<double> d_parameters_omega_ref(8);
  thrust::device_vector<double> d_t(8);
  EPRI_GEN_DATA& gen = d_parameters.gen;

  //For generators
  thrust::device_vector<double> d_dxdt_omega_idx(8);
  thrust::device_vector<double> d_TJ(8);
  thrust::device_vector<double> d_EPS(8);
  thrust::device_vector<double> d_Pmech(8);
  thrust::device_vector<double> d_D(8);
  thrust::device_vector<double> d_dxdt_delta_idx(8);
  thrust::device_vector<double> d_freq_ref(8);

  //Initialization
  std::clock_t start = std::clock();
  for(int i = 0; i < 8; i++){
      //3D Host paramater to device
      d_x_omega_idx[i] = x[i*8 + 0];
      d_x_delta_id[i] = x[i*8 + 1];
      d_x_Eqp_idx[i] = x[i*8 + 2];
      d_dxdt_Eqp_idx[i] = dxdt[i*8 + 2];
      d_gen_a[i] = gen.a;
      d_gen_b[i] = gen.b;
      d_gen_n[i] = gen.n;
      d_gen_Ra[i] = gen.Ra;
      d_gen_Xdp[i] = gen.Xdp;
      d_gen_Xqp[i] = gen.Xqp;
      d_x_Edp_idx[i] = x[i*8 + 3];
      d_gen_bus_id[i] = gen.bus_id;
      d_parameters_Vt_ref[i] = parameters.Vt_ref;
      d_parameters_omega_ref[i] = parameters.omega_ref;
      d_t[i] = t;
      //2D host parameter tp device
      d_Vm[i] = Vm[i];
      d_Vx[i] = Vx[i];
      d_Vy[i] = Vy[i];
      d_Va[i] = Va[i];
      d_Vd[i] = Vd[i];
      d_Vq[i] = Vq[i];
      d_Ifd[i] = Ifd[i];
      d_dIfd_dt[i] = dIfd_dt[i];
      d_Id[i] = Id[i];
      d_Iq[i] = Iq[i];
      d_Telec[i] = Telec[i];
      d_Vm_ref[i] = Vm_ref[i];
      d_omega_ref[i] = omega_ref[i];
  }
  printf("+++Initialization CPU to GPU: %.4f seconds\n\n", (std::clock() - start) / (real__t)CLOCKS_PER_SEC);
   //Vm = sqrt(Vx *Vx + Vy * Vy);
  //Va = atan2(Vy, Vx);
  //Vd = Vm * sin(x[delta_idx] - Va);
  //Vq = Vm * cos(x[delta_idx] - Va);

  //Ifd     = gen.a * x[Eqp_idx] + gen.b * pow(x[Eqp_idx], gen.n);
  //dIfd_dt = gen.a * dxdt[Eqp_idx] + gen.b * gen.n * pow(x[Eqp_idx], gen.n - 1) * dxdt[Eqp_idx];

  std::clock_t start_forloop = std::clock();

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_Vm.begin(), d_Vx.begin(), d_Vy.begin(), d_Va.begin(),d_Vd.begin(), d_Vq.begin(), d_x_delta_id.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_Vm.end(), d_Vx.end(), d_Vy.end(), d_Va.end(), d_Vd.end(), d_Vq.end(), d_x_delta_id.end())), parallel_setup_1_functor());

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_Ifd.begin(), d_gen_a.begin(), d_x_Eqp_idx.begin(), d_gen_b.begin(), d_gen_n.begin(), d_dIfd_dt.begin(), d_dxdt_Eqp_idx.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_Ifd.end(), d_gen_a.end(), d_x_Eqp_idx.end(), d_gen_b.end(), d_gen_n.end(), d_dIfd_dt.end(), d_dxdt_Eqp_idx.end())), parallel_setup_2_functor());

  //update_generator_current(x, gen);
  /* real__t denom = gen.Ra * gen.Ra + gen.Xdp * gen.Xqp;
    Id = (+gen.Ra * (x[Edp_idx] - Vd) + gen.Xqp * (x[Eqp_idx] - Vq)) / denom;
    Iq = (-gen.Xdp * (x[Edp_idx] - Vd) + gen.Ra * (x[Eqp_idx] - Vq)) / denom;
  */

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.begin(), d_gen_Xdp.begin(), d_gen_Xqp.begin(),d_x_Edp_idx.begin(),d_x_Eqp_idx.begin(), d_Vd.begin(), d_Vq.begin(), d_x_omega_idx.begin(), d_Id.begin(), d_Iq.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.end(), d_gen_Xdp.end(), d_gen_Xqp.end(), d_x_Edp_idx.end(), d_x_Eqp_idx.end(), d_Vd.end(), d_Vq.end(), d_x_omega_idx.end(), d_Id.end(), d_Iq.end())), update_generator_current_functor());


  //real__t Psi_q = -(gen_Ra * Id + Vd) / x_omega_idx;
  //real__t Psi_d = +(gen_Ra * Iq + Vq) / x_omega_idx;

  //Telec = Psi_d * Iq - Psi_q * Id;

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.begin(), d_Id.begin(), d_Vd.begin(),d_x_omega_idx.begin(),d_Iq.begin(), d_Vq.begin(), d_Telec.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.end(), d_Id.end(), d_Vd.end(), d_x_omega_idx.end(), d_Iq.end(), d_Vq.end(), d_Telec.end())), parallel_setup_3_functor());


  for(value_type v: dxdt)  {v = 0;}


  //apply_perturbation(t,d_parameters.gen);
   thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_t.begin(), d_gen_bus_id.begin(), d_Vm_ref.begin(),d_parameters_Vt_ref.begin(),d_omega_ref.begin(),  d_parameters_omega_ref.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_t.end(), d_gen_bus_id.end(), d_Vm_ref.end(), d_parameters_Vt_ref.end(), d_omega_ref.end(), d_parameters_omega_ref.end())), apply_perturbation_functor());


  //update_generator_current(x, d_parameters.gen);

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.begin(), d_gen_Xdp.begin(), d_gen_Xqp.begin(),d_x_Edp_idx.begin(),d_x_Eqp_idx.begin(), d_Vd.begin(), d_Vq.begin(), d_x_omega_idx.begin(), d_Id.begin(), d_Iq.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_gen_Ra.end(), d_gen_Xdp.end(), d_gen_Xqp.end(), d_x_Edp_idx.end(), d_x_Eqp_idx.end(), d_Vd.end(), d_Vq.end(), d_x_omega_idx.end(), d_Id.end(), d_Iq.end())), update_generator_current_functor());
  //setup(x, dxdt, d_parameters.gen);
  //printf("parameters.GEN_type=%d\n", parameters.GEN_type);
  
#if DEBUG
  printf("\n\nrunning ODE solver with Gen type %d, GOV type %d, AVR type %d, PSS type %d...\n",
         parameters.GEN_type, parameters.GOV_type, parameters.EXC_type, parameters.PSS_type);
#endif


  //process_EPRI_GEN_TYPE_I_D(const d_vector_type& x, d_vector_type& dxdt, real__t TJ, real__t D)
  

  thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(d_x_omega_idx.begin(), d_omega_ref.begin(),d_dxdt_omega_idx.begin(),d_TJ.begin(), d_EPS.begin(), d_Pmech.begin(), d_Telec.begin(), d_D.begin(), d_dxdt_delta_idx.begin(), d_freq_ref.begin())),thrust::make_zip_iterator(thrust::make_tuple(d_x_omega_idx.end(), d_omega_ref.end(), d_dxdt_omega_idx.end(), d_TJ.end(), d_EPS.end(), d_Pmech.end(), d_Telec.end(), d_D.end(), d_dxdt_delta_idx.end(), d_freq_ref.end())), process_EPRI_GEN_TYPE_I_D_functor());


  printf("+++Computing in GPU: %.4f seconds\n\n", (std::clock() - start_forloop) / (real__t)CLOCKS_PER_SEC);

  std::clock_t start_dtoc = std::clock();
  //copy device parameter to host
  
  for(int i = 0; i < GEN_SIZE; i++){
      gen.a = d_gen_a[i];
      gen.b = d_gen_b[i];
      gen.n = d_gen_n[i];
      gen.Ra = d_gen_Ra[i];
      gen.Xdp = d_gen_Xdp[i];
      gen.Xqp = d_gen_Xqp[i];
      gen.bus_id = d_gen_bus_id[i];
      parameters.Vt_ref = d_parameters_Vt_ref[i];
      parameters.omega_ref = d_parameters_omega_ref[i];
      //2D host parameter tp device
      Vm[i] = d_Vm[i];
      Vx[i] = d_Vx[i];
      Vy[i] = d_Vy[i];
      Va[i] = d_Va[i];
      Vd[i] = d_Vd[i];
      Vq[i] = d_Vq[i];
      Ifd[i] = d_Ifd[i];
      dIfd_dt[i] = d_dIfd_dt[i];
      Id[i] = d_Id[i];
      Iq[i] = d_Iq[i];
      Telec[i] = d_Telec[i];
      Vm_ref[i] = d_Vm_ref[i];
      omega_ref[i] = d_omega_ref[i];
  }
  printf("+++From GPU TO CPU: %.4f seconds\n\n", (std::clock() - start_dtoc) / (real__t)CLOCKS_PER_SEC);


  /*
  switch (parameters.PSS_type) {
    case 0: VS = 0; break;
    case 1: VS = process_EPRI_PSS_TYPE_I(x, dxdt, parameters.pss_1);    break;
    case 2: VS = process_EPRI_PSS_TYPE_II(x, dxdt, parameters.pss_2);   break;
    case 4: VS = process_EPRI_PSS_TYPE_IV(x, dxdt, parameters.pss_4_6); break;
    case 5: VS = process_EPRI_PSS_TYPE_V(x, dxdt, parameters.pss_5);    break;
    case 8: VS = process_EPRI_PSS_TYPE_VIII(x, dxdt, parameters.pss_8); break;
    default: {std::cerr << "Error: unsupported PSS type...\n"; std::terminate(); break;}
  }
  
  switch (parameters.EXC_type) {
    case 0:  Efd = Efd0; break;
    case 1:  Efd = process_EPRI_EXC_TYPE_I(x, dxdt, parameters.exc_1);       break;
    case 2:  Efd = process_EPRI_EXC_TYPE_II(x, dxdt, parameters.exc_2);      break;
    case 3:  Efd = process_EPRI_EXC_TYPE_III(x, dxdt, parameters.exc_3_10);  break;
    case 4:  Efd = process_EPRI_EXC_TYPE_IV(x, dxdt, parameters.exc_3_10);   break;
    case 5:  Efd = process_EPRI_EXC_TYPE_V(x, dxdt, parameters.exc_3_10);    break;
    case 6:  Efd = process_EPRI_EXC_TYPE_VI(x, dxdt, parameters.exc_3_10);   break;
    case 7:  Efd = process_EPRI_EXC_TYPE_VII(x, dxdt, parameters.exc_3_10);  break;
    case 8:  Efd = process_EPRI_EXC_TYPE_VIII(x, dxdt, parameters.exc_3_10); break;
    case 9:  Efd = process_EPRI_EXC_TYPE_IX(x, dxdt, parameters.exc_3_10);   break;
    case 10: Efd = process_EPRI_EXC_TYPE_X(x, dxdt, parameters.exc_3_10);    break;
    case 11: Efd = process_EPRI_EXC_TYPE_XI(x, dxdt, parameters.exc_11_12);  break;
    case 12: Efd = process_EPRI_EXC_TYPE_XII(x, dxdt, parameters.exc_11_12); break;
    default: {std::cerr << "Error: unsupported excitor (AVR) type...\n"; std::terminate(); break;}
  }
  
  switch (parameters.GOV_type) {
    case 0: Pmech = Pe_ref; break;
    case 1: Pmech = process_EPRI_GOV_TYPE_I(x, dxdt, parameters.gov_1);    break;
    case 3: Pmech = process_EPRI_GOV_TYPE_III(x, dxdt, parameters.gov_3);  break;
    case 4: Pmech = process_EPRI_GOV_TYPE_IV(x, dxdt, parameters.gov_4);   break;
    case 5: Pmech = process_EPRI_GOV_TYPE_V(x, dxdt, parameters.gov_5);    break;
//    case 6: Pmech = process_EPRI_GOV_TYPE_VI(x, dxdt, parameters.gov_6); break;
    case 7: Pmech = process_EPRI_GOV_TYPE_VII(x, dxdt, parameters.gov_7);  break;
    case 8: Pmech = process_EPRI_GOV_TYPE_VIII(x, dxdt, parameters.gov_8); break;
    case 9: Pmech = process_EPRI_GOV_TYPE_IX(x, dxdt, parameters.gov_9);   break;
    default: {std::cerr << "Error: unsupported governor (GOV) type...\n"; std::terminate(); break;}
  }
  */

  //switch (parameters.GEN_type) {
    //case 0:
    //case 1: process_EPRI_GEN_TYPE_I(x, dxdt, parameters.gen);   break;
    //case 3: process_EPRI_GEN_TYPE_III(x, dxdt, parameters.gen); break;
    //case 6: process_EPRI_GEN_TYPE_VI(x, dxdt, parameters.gen);  break;
    //case 6: process_EPRI_GEN_TYPE_I_D(x, dxdt, parameters.gen.TJ, parameters.gen.D);  break;
    //default: {std::cerr << "Error: unsupported generator (GEN) type...\n"; std::terminate(); break;}
  //}


//  print_dxdt(dxdt);
}

}  // namespace transient_analysis
