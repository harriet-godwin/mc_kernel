program kerner_code

#ifndef include_mpi
    use mpi
#endif
    use commpi,                      only: ppinit, pbroadcast_int, ppend, pabort
    use global_parameters,           only: sp, dp, pi, deg2rad, verbose, init_random_seed, &
                                           master, lu_out, myrank
    use simple_routines,             only: lowtrim

    use inversion_mesh,              only: inversion_mesh_data_type
    use type_parameter,              only: parameter_type
    use ftnunit,                     only: runtests_init, runtests, runtests_final
    use unit_tests,                  only: test_all
    use slave_mod,                   only: do_slave
    use master_module,               only: do_master
    use work_type_mod,               only: init_work_type
    use plot_wavefields_mod,         only: plot_wavefields
    use backgroundmodel,             only: nmodel_parameters
    use heterogeneities,             only: nmodel_parameters_hetero

    implicit none

#ifdef include_mpi
    include 'mpif.h'
#endif

    type(inversion_mesh_data_type)      :: inv_mesh
    type(parameter_type)                :: parameters

    integer                             :: nvertices_per_elem
    integer                             :: nvertices_per_task
    integer                             :: nbasisfuncs_per_elem
    integer                             :: nbasisfuncs_per_task

    verbose = 0

    call init_random_seed()

    call runtests_init
    call runtests( test_all )
    call runtests_final

    verbose = 1


    call ppinit
    write(lu_out,*) '***************************************************************'
    write(lu_out,*) ' MPI communication initialized, I have rank', myrank
    write(lu_out,*) '***************************************************************'
   
    if (master) then
      call start_clock_master()
    else
      call start_clock_slave()
    end if

    call parameters%read_parameters()
    call parameters%read_source()
    call parameters%read_receiver()
    


    select case(trim(parameters%whattodo))
    case('integratekernel')

       if (master) then
           ! Get type of mesh and number of vertices per element
           
           select case(lowtrim(parameters%mesh_file_type))
           case('tetrahedral') 
               nvertices_per_elem = 4
               nbasisfuncs_per_elem = 4
           case('abaqus') 
               call inv_mesh%read_abaqus_meshtype(parameters%mesh_file,parameters%int_type)
               nbasisfuncs_per_elem = inv_mesh%nbasisfuncs_per_elem
               nvertices_per_elem = inv_mesh%nvertices_per_elem
               call inv_mesh%freeme()
           case default
               write(*,*) 'Unknown mesh type: ', trim(parameters%mesh_file_type)
               call pabort(do_traceback=.false.)
           end select
       end if

       call pbroadcast_int(nbasisfuncs_per_elem, 0)
       call pbroadcast_int(nvertices_per_elem, 0)

       nvertices_per_task = parameters%nelems_per_task * nvertices_per_elem
       nbasisfuncs_per_task = parameters%nelems_per_task * nbasisfuncs_per_elem

       call pbroadcast_int(nbasisfuncs_per_task, 0)
       call pbroadcast_int(nvertices_per_task, 0)

       write(lu_out,*) '***************************************************************'
       write(lu_out,*) ' Initialize MPI work type'
       write(lu_out,*) '***************************************************************'


        call init_work_type(nkernel                  = parameters%nkernel,          &
                            nelems_per_task          = parameters%nelems_per_task,  &
                            nvertices                = nvertices_per_task,          &
                            nvertices_per_elem       = nvertices_per_elem,          &
                            nbasisfuncs_per_elem     = nbasisfuncs_per_elem,        &
                            nmodel_parameters        = nmodel_parameters,           &
                            nmodel_parameters_hetero = nmodel_parameters_hetero)

      

        write(lu_out,*) '***************************************************************'
        write(lu_out,*) ' Master and slave part ways'
        write(lu_out,*) '***************************************************************'
        if (master) then
           call do_master()
        else
           call do_slave()
        endif
 
        call ppend()
        call end_clock()   
  
    case('plot_wavefield')
        if (master) then
            call start_clock_slave()
            call plot_wavefields()
            call end_clock()
        else
            print *, 'Nothing to do on rank ', myrank
        end if
    end select


    write(lu_out,*)
    write(lu_out,*) ' Finished!'
contains


!-----------------------------------------------------------------------------
!> Driver routine to start the timing for the master, using the clocks_mod module.
subroutine start_clock_master
  use global_parameters
  use clocks_mod, only : clock_id, clocks_init
  
  implicit none
  
  character(len=8)  :: mydate
  character(len=10) :: mytime

  call date_and_time(mydate,mytime) 
  write(lu_out,11) mydate(5:6), mydate(7:8), mydate(1:4), mytime(1:2), mytime(3:4)

11 format('     Kerner started on ', A2,'/',A2,'/',A4,' at ', A2,'h ',A2,'min',/)


  call clocks_init(0)

  id_read_params     = clock_id('Read parameters')
  id_create_tasks    = clock_id('Create tasks for slaves')
  id_get_next_task   = clock_id('Get next task for Slave')
  id_extract         = clock_id('Extract receive buffer')
  id_mpi             = clock_id('MPI communication with Slaves')
  id_dump            = clock_id('Dump intermediate results')
  id_write_kernel    = clock_id('Write Kernels to disk')
  id_mult_kernel     = clock_id('Multiply Kernels with Model')


end subroutine start_clock_master
!=============================================================================

!-----------------------------------------------------------------------------
!> Driver routine to start the timing for the slave, using the clocks_mod module.
subroutine start_clock_slave
  use global_parameters
  use clocks_mod, only : clock_id, clocks_init
  
  implicit none
  
  character(len=8)  :: mydate
  character(len=10) :: mytime

  call date_and_time(mydate,mytime) 
  write(lu_out,11) mydate(5:6), mydate(7:8), mydate(1:4), mytime(1:2), mytime(3:4)

11 format('     Kerner started on ', A2,'/',A2,'/',A4,' at ', A2,'h ',A2,'min',/)


  call clocks_init(0)

  id_read_params     = clock_id('Read parameters')
  id_init_fft        = clock_id('Initialize FFT plan')
  id_fft             = clock_id('FFT routines')
  id_bwd             = clock_id('Reading bwd field')
  id_fwd             = clock_id('Reading fwd field')
  id_kdtree          = clock_id(' - KD-tree lookup (only fwd)')
  id_find_point_fwd  = clock_id(' - Find next GLL point (only fwd)')
  id_find_point_bwd  = clock_id(' - Find next GLL point (only bwd)')
  id_load_strain     = clock_id(' - Load_strain (fwd and bwd)')
  id_netcdf          = clock_id(' - - NetCDF routines')
  id_rotate          = clock_id(' - - Rotate fields')
  id_buffer          = clock_id(' - - Buffer routines')
  id_calc_strain     = clock_id(' - - Calculate strain')
  id_lagrange        = clock_id(' - - Lagrange interpolation')
  id_mc              = clock_id('Monte Carlo routines')
  id_filter_conv     = clock_id('Filtering and convolution')
  id_inv_mesh        = clock_id('Inversion mesh routines')
  id_int_model       = clock_id('Integrate model paramaters')
  id_int_hetero      = clock_id('Integrate heterogeneity model')
  id_kernel          = clock_id('Kernel routines')
  id_init            = clock_id('Initialization per task')
  id_mpi             = clock_id('MPI communication with Master')
  id_out             = clock_id('Write wavefields to disk')
  id_finalize        = clock_id('Finalization of output files')
  id_element         = clock_id('Time spent for one element')


end subroutine start_clock_slave
!=============================================================================

!-----------------------------------------------------------------------------
subroutine end_clock 
  !
  ! Wapper routine to end timing and display clock informations.
  !
  !-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

  use clocks_mod, only : clocks_exit

  implicit none

  write(lu_out,*)
  write(lu_out,"(10x,'Summary of timing measurements:')")
  write(lu_out,*)

  call clocks_exit(0)

  write(lu_out,*)

end subroutine end_clock
!=============================================================================
end program
