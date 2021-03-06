!******************************************************************************
!
!    This file is part of:
!    MC Kernel: Calculating seismic sensitivity kernels on unstructured meshes
!    Copyright (C) 2016 Simon Staehler, Martin van Driel, Ludwig Auer
!
!    You can find the latest version of the software at:
!    <https://www.github.com/tomography/mckernel>
!
!    MC Kernel is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    MC Kernel is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with MC Kernel. If not, see <http://www.gnu.org/licenses/>.
!
!******************************************************************************

!=========================================================================================
module test_type_parameter

  use global_parameters
  use type_parameter, only : parameter_type
  use ftnunit
  implicit none
  public
contains


!-----------------------------------------------------------------------------------------
subroutine test_parameter_reading
   use readfields,     only : semdata_type
   use fft,            only : rfft_type
   type(parameter_type)    :: parameters
   type(semdata_type)      :: sem_data
   type(rfft_type)         :: fft_data
   integer                 :: nomega, ntimes 
   real(kind=dp)           :: df
   logical                 :: ref_var(6)
   
   call parameters%read_parameters('./inparam_test')
   call parameters%read_source()
   call parameters%read_receiver()

   ! Do checks on receivers
   ! Check, whether number of receivers is correct
   call assert_equal(parameters%nrec, 2, '2 receivers read in')

   call sem_data%set_params(parameters%fwd_dir, parameters%bwd_dir, 100, 100,    &
                            parameters%strain_type_fwd, parameters%source%depth, &
                            1, .false.)
   call sem_data%open_files()
   call sem_data%read_meshes()
   call sem_data%load_seismogram(parameters%receiver, parameters%source)

   ! Initialize FFT - just needed to get df and nomega
   call fft_data%init(ntimes_in = sem_data%ndumps,     &
                      ndim      = sem_data%get_ndim(), &
                      ntraces   = 1,                   &
                      dt        = sem_data%dt)

   ntimes = fft_data%get_ntimes()
   nomega = fft_data%get_nomega()
   df     = fft_data%get_df()
   call fft_data%freeme()

   call parameters%read_filter(nomega=nomega, df=df)
     
   ! Do checks on filters
   call assert_equal(parameters%nfilter, 4, '4 Filters in input file')
   call assert_true(parameters%filter(1, 1)%name=='BW_4_40s', 'Filter 1, name: BW_4_40s')
   call assert_true(parameters%filter(2, 1)%name=='Identical', 'Filter 2, name:Identical')
   call assert_true(parameters%filter(3, 1)%name=='Gabor_60', 'Filter 3, name: Gabor_60')
   call assert_true(parameters%filter(4, 1)%name=='Gabor_80', 'Filter 4, name: Gabor_80')

   call assert_comparable(parameters%filter(1, 1)%frequencies, [40.d0, 0.5d0, 0.d0, 0.d0], &
                          1d-10, 'Frequencies of filter 1 correct')
   call assert_comparable(parameters%filter(2, 1)%frequencies, [0.d0, 0.0d0, 0.d0, 0.d0], &
                          1d-10, 'Frequencies of filter 2 correct')
   call assert_comparable(parameters%filter(3, 1)%frequencies, [60.d0, 0.5d0, 0.d0, 0.d0], &
                          1d-10, 'Frequencies of filter 3 correct')
   call assert_comparable(parameters%filter(4, 1)%frequencies, [80.d0, 0.5d0, 0.d0, 0.d0], &
                          1d-10, 'Frequencies of filter 4 correct')

   call assert_true(parameters%filter(1, 1)%filterclass=='Butterw_LP_O4', 'Filter 1, type: Gabor')
   call assert_true(parameters%filter(2, 1)%filterclass=='ident', 'Filter 2, type: Gabor')
   call assert_true(parameters%filter(3, 1)%filterclass=='Gabor', 'Filter 1, type: Gabor')
   call assert_true(parameters%filter(4, 1)%filterclass=='Gabor', 'Filter 2, type: Gabor')


   call parameters%read_kernel(sem_data, parameters%filter)

   ! Check, whether receiver and kernel file has been read in correctly
   call assert_equal(parameters%receiver(1)%nkernel, 3, 'Receiver 1 has 3 kernels')
   call assert_equal(parameters%receiver(2)%nkernel, 4, 'Receiver 2 has 4 kernel')

   ! Check, whether firstkernel and lastkernel are set correctly
   call assert_equal(parameters%receiver(1)%firstkernel, 1, 'Rec 1: first kernel: 1')
   call assert_equal(parameters%receiver(2)%firstkernel, 4, 'Rec 2: first kernel: 4')
   call assert_equal(parameters%receiver(1)%lastkernel, 3, 'Rec 1: last kernel: 1')
   call assert_equal(parameters%receiver(2)%lastkernel, 7, 'Rec 1: last kernel: 1')

   ! Check, whether needs_basekernel has been set correctly
   ! First receiver should need lambda, mu and A and C base kernels
   ref_var = [.true., .true., .false., .true., .false., .true.] 
   call assert_true(parameters%receiver(1)%needs_basekernel.eqv.ref_var, &
                    'First receiver should need lambda, mu, A and C base kernels')

   ref_var = [.true., .true., .true., .true., .true., .true.] 
   call assert_true(parameters%receiver(2)%needs_basekernel.eqv.ref_var, &
                    'Second receiver should need all base kernels')

   ! Check whether needs_basekernel has been set correctly on the kernels themselves

   ! Kernels of receiver 1
   ref_var = [.true., .false., .false., .false., .false., .false.] 
   call assert_true(parameters%kernel(1)%needs_basekernel.eqv.ref_var, &
                    'Kernel 1 should need only lambda base kernels (lambda)')

   ref_var = [.true., .false., .false., .true., .false., .true.] 
   call assert_true(parameters%kernel(2)%needs_basekernel.eqv.ref_var, &
                    'Kernel 2 should need lambda, a and c base kernels (eta)')

   ref_var = [.false., .true., .false., .false., .false., .false.] 
   call assert_true(parameters%kernel(3)%needs_basekernel.eqv.ref_var, &
                    'Kernel 3 should need only mu base kernels (mu)')

   ! Kernels of receiver 2
   ref_var = [.true., .true., .true., .true., .true., .true.] 
   call assert_true(parameters%kernel(4)%needs_basekernel.eqv.ref_var, &
                    'Kernel 4 should need all base kernels (rho)')

   ref_var = [.true., .false., .false., .false., .false., .false.] 
   call assert_true(parameters%kernel(5)%needs_basekernel.eqv.ref_var, &
                    'Kernel 5 should need only lambda base kernels (vp)')

   ref_var = [.true., .true., .false., .false., .false., .false.] 
   call assert_true(parameters%kernel(6)%needs_basekernel.eqv.ref_var, &
                    'Kernel 6 should need lambda and mu base kernels (vs)')

   ref_var = [.true., .false., .false., .true., .false., .true.] 
   call assert_true(parameters%kernel(7)%needs_basekernel.eqv.ref_var, &
                    'Kernel 7 should need lambda, a and c base kernels (eta)')


end subroutine test_parameter_reading
!-----------------------------------------------------------------------------------------

end module test_type_parameter                 
!=========================================================================================
