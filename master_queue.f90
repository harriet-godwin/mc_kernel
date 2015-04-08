!=========================================================================================
module master_queue
  use global_parameters,           only: sp, dp, lu_out, long
  use inversion_mesh,              only: inversion_mesh_data_type
  use type_parameter,              only: parameter_type
  use simple_routines,             only: lowtrim
  use nc_routines,                 only: nc_create_file, nc_close_file, &
                                         nc_putvar_by_name
  use backgroundmodel,             only: nmodel_parameters, parameter_name
  use heterogeneities,             only: nmodel_parameters_hetero,parameter_name_het, &
                                         parameter_name_het_store
  implicit none
  private
  
  public :: init_queue, get_next_task, extract_receive_buffer, finalize, dump_intermediate

  type(inversion_mesh_data_type), save :: inv_mesh
  type(parameter_type),           save :: parameters
  integer, allocatable,           save :: tasks(:), elems_in_task(:,:)
  real(kind=dp), allocatable,     save :: K_x(:,:), Var(:,:), Bg_Model(:,:), Het_Model(:,:)
  integer,       allocatable,     save :: connectivity(:,:)
  integer,       allocatable,     save :: niterations(:,:), element_proc(:)
  real(kind=dp), allocatable,     save :: computation_time(:)
  integer(kind=long),             save :: iclockold_mpi
  integer,                        save :: ncid_intermediate

contains

!-----------------------------------------------------------------------------------------
subroutine init_queue(ntasks, inparam_file)
! anything that should be done before starting the loop over the work. for now,
! the number of tasks is fixed here

  use clocks_mod,    only                   : tick
  use global_parameters, only               : id_read_params, id_create_tasks
  use work_type_mod, only                   : wt
  integer, intent(out)                     :: ntasks
  character(len=*), intent(in), optional   :: inparam_file
  integer                                  :: itask, nelems, iel
  integer(kind=long)                       :: iclockold
  character(len=64)                        :: fmtstring, filename
  
  iclockold = tick()

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Read input files for parameters, source and receivers'
  write(lu_out,'(A)') '***************************************************************'
  if (present(inparam_file)) then !only relevant for unit tests
    call parameters%read_parameters(trim(inparam_file))
  else
    call parameters%read_parameters()
  end if
  call parameters%read_source()
  call parameters%read_receiver()

  ! Master and slave part ways here for some time. 
  ! Master reads in the inversion mesh, slaves initialize the FFT

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Read inversion mesh'
  write(lu_out,'(A)') '***************************************************************'
  select case(lowtrim(parameters%mesh_file_type))
  case('tetrahedral') 
    call inv_mesh%read_tet_mesh(parameters%mesh_file_vert, &
                                parameters%mesh_file_face, &
                                parameters%int_type)
  case('abaqus')
    call inv_mesh%read_abaqus_mesh(parameters%mesh_file, &
                                   parameters%int_type)
  end select
  
  wt%ielement_type = inv_mesh%get_element_type()
  print *, 'Inversion mesh type: ', wt%ielement_type
  
  nelems    = inv_mesh%get_nelements()
  allocate(connectivity(inv_mesh%nvertices_per_elem, nelems))
  connectivity = inv_mesh%get_connectivity()
  
  ! Master and slave synchronize again

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Define filters'
  write(lu_out,'(A)') '***************************************************************'
  call parameters%read_filter()

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Define kernels'
  write(lu_out,'(A)') '***************************************************************'
  call parameters%read_kernel()

  iclockold = tick(id=id_read_params, since=iclockold)

  fmtstring = '(A, I8, A, I8)'
  ! Calculate number of tasks
  ntasks = ceiling(real(inv_mesh%get_nelements()) / parameters%nelems_per_task)
  print fmtstring, '  nelements: ',  nelems, ', ntasks: ', ntasks
   
  allocate(tasks(ntasks))
  allocate(elems_in_task(ntasks, parameters%nelems_per_task))
  do itask = 1, ntasks
     tasks(itask) = itask
     do iel = 1, parameters%nelems_per_task
         if (iel + (itask-1) * parameters%nelems_per_task <= nelems) then
             elems_in_task(itask, iel) = iel + (itask-1) * parameters%nelems_per_task
         else
             elems_in_task(itask, iel) = -1
         end if
     end do
  enddo
  

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Allocate variables to store result'
  write(lu_out,'(A)') '***************************************************************'
  allocate(K_x(inv_mesh%get_nbasisfuncs(parameters%int_type), parameters%nkernel))
  K_x(:,:) = 0.0
  allocate(Var(inv_mesh%get_nbasisfuncs(parameters%int_type), parameters%nkernel))
  Var(:,:) = 0.0
  allocate(Bg_Model(inv_mesh%get_nbasisfuncs(parameters%int_type),  &
                    nmodel_parameters))
  allocate(Het_Model(inv_mesh%get_nbasisfuncs(parameters%int_type),  &
                    nmodel_parameters_hetero))
  Bg_Model(:,:) = 0.0
  Het_Model(:,:) = 0.0

  allocate(niterations(nelems, parameters%nkernel))
  allocate(computation_time(nelems))
  allocate(element_proc(nelems))
  niterations(:,:)     = -1
  computation_time(:)  = -1
  element_proc(:)      = -1
  

  iclockold = tick(id=id_create_tasks, since=iclockold)

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Create file for intermediate results '
  write(lu_out,'(A)') '***************************************************************'
  filename = 'intermediate_results.nc'
  call nc_create_file(filename = filename, ncid = ncid_intermediate, overwrite=.true.)

  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'K_x',             & 
                         values  = real(K_x, kind=sp) )
  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'Var',             & 
                         values  = real(Var, kind=sp) )
  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'Bg_Model',        & 
                         values  = real(Bg_Model, kind=sp) )
  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'Het_Model',        & 
                         values  = real(Het_Model, kind=sp) )
  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'niterations',     & 
                         values  = niterations )
  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'element_proc',    & 
                         values  = element_proc )


  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') ' Starting to distribute the work'
  write(lu_out,'(A)') '***************************************************************'
  
end subroutine init_queue
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine get_next_task(itask)
! put a new piece of work in the send buffer
  use clocks_mod,    only    : tick
  use work_type_mod, only    : wt
  use global_parameters, only: id_get_next_task
  integer, intent(in)       :: itask
  integer                   :: iel, ielement, ivert
  integer(kind=long)        :: iclockold
  integer, allocatable      :: ivertex(:)

  iclockold = tick()
  allocate(ivertex(inv_mesh%nvertices_per_elem))

  wt%itask = itask

  do iel = 1, parameters%nelems_per_task
      ielement = elems_in_task(itask, iel)
      if (ielement.eq.-1) cycle
      ivertex = [( (iel-1) * inv_mesh%nvertices_per_elem + ivert, &
                   ivert = 1, inv_mesh%nvertices_per_elem )]
      wt%vertices(:, ivertex) = inv_mesh%get_element(ielement)
      wt%connectivity(:, iel) = ivertex
  end do
  
  iclockold_mpi = tick(id=id_get_next_task, since=iclockold)

end subroutine get_next_task
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine extract_receive_buffer(itask, irank)
! extract information received back from a slave

  use clocks_mod,    only    : tick
  use global_parameters, only: id_extract, id_mpi
  use work_type_mod, only    : wt
  integer, intent(in)       :: itask, irank
  integer                   :: iel, ielement, ibasisfunc, ipoint
  integer(kind=long)        :: iclockold

  if (.not.iclockold_mpi==-1) then
    iclockold = tick(id=id_mpi, since=iclockold_mpi)
    iclockold_mpi = -1
  else
    iclockold = tick()
  end if

  ! extract from receive buffer
  do iel = 1, parameters%nelems_per_task
    ielement = elems_in_task(itask, iel)
    if (ielement.eq.-1) cycle
    do ibasisfunc = 1, inv_mesh%nbasisfuncs_per_elem

      ! are we in volumetric or vertex mode?
      select case(trim(parameters%int_type))
      case('onvertices')         
        ipoint = connectivity(ibasisfunc, ielement)
        K_x(ipoint, :)       = K_x(ipoint,:)       + wt%kernel_values(:, ibasisfunc, iel)
        Var(ipoint, :)       = Var(ipoint,:)       + wt%kernel_variance(:, ibasisfunc, iel) 
        Bg_Model(ipoint, :)  = Bg_Model(ipoint,:)  + wt%model(:, ibasisfunc, iel)
        Het_Model(ipoint, :) = Het_Model(ipoint,:) + wt%hetero_model(:, ibasisfunc, iel) 
      case('volumetric')
        K_x(ielement,:)      = K_x(ielement,:) &
                               + wt%kernel_values(:, ibasisfunc, iel) 
        Var(ielement,:)      = Var(ielement,:) &
                               + wt%kernel_variance(:, ibasisfunc, iel)   
        Bg_Model(ielement,:) = Bg_Model(ielement,:) &
                               + wt%model(:, ibasisfunc, iel)   
        Het_Model(ielement, :) = Het_Model(ielement,:)  &
                               + wt%hetero_model(:, ibasisfunc, iel) 
      end select

    end do
    niterations(ielement,:)     = wt%niterations(:,iel)
    computation_time(ielement)  = wt%computation_time(iel)
    element_proc(ielement)      = irank 
  end do

  iclockold = tick(id=id_extract, since=iclockold)

end subroutine extract_receive_buffer
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine finalize()
  integer                       :: ikernel, imodel_parameter
  real(kind=sp), allocatable    :: rel_error(:)
  character(len=64)             :: xdmf_varname
  real(kind=dp)                 :: total_time
  real(kind=dp)                 :: delay_time
  integer                       :: imodel


  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') 'Finalize intermediate file'
  write(lu_out,'(A)') '***************************************************************'
  call nc_close_file(ncid = ncid_intermediate)

  write(lu_out,'(A)') '***************************************************************'
  write(lu_out,'(A)') 'Initialize output file'
  write(lu_out,'(A)') '***************************************************************'

  ! Save big kernel variable to disk
  write(lu_out,*) 'Write Kernel to disk'

  ! Select dump format
  select case(trim(parameters%dump_type))

  ! Save kernels in xdmf format
  case ('xdmf')

    do imodel = 1, nmodel_parameters
      print *, imodel, parameter_name(imodel), minval(Bg_Model(:,imodel)), maxval(Bg_Model(:,imodel))
    end do
    do imodel = 1, nmodel_parameters_hetero
      print *, imodel, parameter_name_het(imodel), minval(Het_Model(:,imodel)), maxval(Het_Model(:,imodel))
    end do
                                      
     ! Distiguish between volumetric and node-based mode
     select case(trim(parameters%int_type))
     case ('onvertices')
        call inv_mesh%init_node_data()

        call inv_mesh%add_node_variable(var_name    = 'kernel',           &
                                        nentries    = parameters%nkernel, &
                                        entry_names = [('K_x_'//parameters%kernel(ikernel)%name, &
                                                        ikernel = 1, parameters%nkernel)] )

        call inv_mesh%add_node_variable(var_name    = 'error',            &
                                        nentries    = parameters%nkernel, &
                                        entry_names = [('err_'//parameters%kernel(ikernel)%name, &
                                                        ikernel = 1, parameters%nkernel)] )

        call inv_mesh%add_node_variable(var_name    = 'model',                                  &
                                        nentries    = nmodel_parameters,              &
                                        entry_names = parameter_name )

        call inv_mesh%add_node_variable(var_name    = 'hetero',                                  &
                                        nentries    = nmodel_parameters_hetero,              &
                                        entry_names = parameter_name_het_store )

                                                     
        call inv_mesh%add_node_data(var_name = 'kernel',                      &
                                    values   = real(K_x, kind=sp) )
        call inv_mesh%add_node_data(var_name = 'error',                       &
                                    values   = real(sqrt(Var/K_x), kind=sp) )
        call inv_mesh%add_node_data(var_name = 'model',                       &
                                    values   = real(Bg_Model, kind=sp) )
        call inv_mesh%add_node_data(var_name = 'hetero',                       &
                                    values   = real(Het_Model, kind=sp) )

                                      
     case ('volumetric')
        call inv_mesh%init_cell_data()

        call inv_mesh%add_cell_variable(var_name    = 'kernel',           &
                                        nentries    = parameters%nkernel, &
                                        entry_names = [('K_x_'//parameters%kernel(ikernel)%name, &
                                                        ikernel = 1, parameters%nkernel)] )

        call inv_mesh%add_cell_variable(var_name    = 'error',            &
                                        nentries    = parameters%nkernel, &
                                        entry_names = [('err_'//parameters%kernel(ikernel)%name, &
                                                        ikernel = 1, parameters%nkernel)] )

        call inv_mesh%add_cell_variable(var_name    = 'model',                                  &
                                        nentries    = nmodel_parameters,              &
                                        entry_names = parameter_name )

        call inv_mesh%add_cell_variable(var_name    = 'hetero',                                  &
                                        nentries    = nmodel_parameters_hetero,              &
                                        entry_names = parameter_name_het_store )

                                                     
        call inv_mesh%add_cell_data(var_name = 'kernel',                      &
                                    values   = real(K_x, kind=sp) )
        call inv_mesh%add_cell_data(var_name = 'error',                       &
                                    values   = real(sqrt(Var/K_x), kind=sp) )
        call inv_mesh%add_cell_data(var_name = 'model',                       &
                                    values   = real(Bg_Model, kind=sp) )
        call inv_mesh%add_cell_data(var_name = 'hetero',                       &
                                    values   = real(Het_Model, kind=sp) )


     end select
  
  ! Save kernels in Yale-style csr format
  case ('csr')

     select case(trim(parameters%int_type))
     case ('onvertices')

        call inv_mesh%dump_node_data_csr ( real(K_x(:,:), kind=sp),  &
                                           parameters%nkernel,       &
                                           parameters%allowed_error, & 
                                           trim(parameters%output_file)//'_kernel')


     case ('volumetric')

        call inv_mesh%dump_cell_data_csr ( real(K_x(:,:), kind=sp),  &
                                           parameters%nkernel,       &
                                           parameters%allowed_error, & 
                                           trim(parameters%output_file)//'_kernel')


     end select

  ! Save kernels in ASCII format
  case ('ascii')

     select case(trim(parameters%int_type))
     case ('onvertices')

        call inv_mesh%dump_node_data_ascii ( real(K_x(:,:), kind=sp),  &
                                           parameters%nkernel,         &
                                           parameters%allowed_error,   & 
                                           trim(parameters%output_file)//'_kernel')


     case ('volumetric')

        call inv_mesh%dump_cell_data_ascii ( real(K_x(:,:), kind=sp),  &
                                           parameters%nkernel,         &
                                           parameters%allowed_error,   & 
                                           trim(parameters%output_file)//'_kernel')

     end select


  end select


  ! Save mesh partition and convergence information
  write(lu_out,*) 'Write mesh partition and convergence to disk'

  call inv_mesh%init_cell_data()
  call inv_mesh%add_cell_variable(var_name    = 'niterations',      &
                                  nentries    = parameters%nkernel, &
                                  entry_names = [('nit_'//parameters%kernel(ikernel)%name, &
                                                  ikernel = 1, parameters%nkernel)] )
  call inv_mesh%add_cell_variable(var_name    = 'computation_time', &
                                  nentries    = 1 )                 
  call inv_mesh%add_cell_variable(var_name    = 'element_proc', &
                                  nentries    = 1 )

  call inv_mesh%add_cell_data(var_name = 'niterations',       &
                              values   = real(niterations, kind=sp))
  call inv_mesh%add_cell_data(var_name = 'computation_time',  &
                              values   = reshape(real(computation_time, kind=sp), [size(element_proc,1), 1]))
  call inv_mesh%add_cell_data(var_name = 'element_proc',      &
                              values   = reshape(real(element_proc, kind=sp), [size(element_proc,1), 1]))


  call inv_mesh%dump_data_xdmf(trim(parameters%output_file)//'_kernel')
      
  call inv_mesh%free_node_and_cell_data()
  call inv_mesh%freeme()

  ! Multiply kernels with model to get absolute traveltime of "phase"
  do ikernel = 1, parameters%nkernel
    total_time = sum(K_x(:, ikernel) * Bg_Model(:, parameters%kernel(ikernel)%model_parameter_index))
    print '(A,": ",E15.5," s")', parameters%kernel(ikernel)%name, total_time
  end do

  ! Multiply relative kernels with heterogeneities to get traveltime shift
  if (parameters%int_over_hetero) then     
     do ikernel = 1, parameters%nkernel
        delay_time = sum(K_x(:, ikernel) * Het_Model(:, parameters%kernel(ikernel)%hetero_parameter_index))/100.d0
        print '(A,": ",E15.5," s")', parameters%kernel(ikernel)%name, delay_time
     end do
  end if
     

end subroutine finalize
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
subroutine dump_intermediate(itask)
  use clocks_mod,        only : tick
  use global_parameters, only : id_dump, long, int4
  integer, intent(in)        :: itask
  integer(kind=int4)         :: iel, ielement, ibasisfunc, ipoint
  integer(kind=long)         :: iclockold

  iclockold = tick()

  do iel = 1, parameters%nelems_per_task
    ielement = elems_in_task(itask, iel)
    if (ielement.eq.-1) cycle

    ! are we in volumetric or vertex mode?
    select case(trim(parameters%int_type))
    case('onvertices')         
      do ibasisfunc = 1, inv_mesh%nbasisfuncs_per_elem
        ipoint = connectivity(ibasisfunc, ielement)
        call nc_putvar_by_name(ncid    = ncid_intermediate, &
                               varname = 'K_x',             & 
                               values  = real(K_x(ipoint:ipoint, :), kind=sp),    &
                               start   = [ipoint, 1],       &
                               count   = [1, parameters%nkernel] )
        call nc_putvar_by_name(ncid    = ncid_intermediate, &
                               varname = 'Var',             & 
                               values  = real(Var(ipoint, :), kind=sp),    &
                               start   = [ipoint, 1],       &
                               count   = [1, parameters%nkernel] )
        call nc_putvar_by_name(ncid    = ncid_intermediate, &
                               varname = 'Bg_Model',        & 
                               values  = real(Bg_Model(ipoint, :), kind=sp),&
                               start   = [ipoint, 1],        &
                               count   = [1, nmodel_parameters] )
        call nc_putvar_by_name(ncid    = ncid_intermediate, &
                               varname = 'Het_Model',        & 
                               values  = real(Het_Model(ipoint, :), kind=sp),&
                               start   = [ipoint, 1],        &
                               count   = [1, nmodel_parameters_hetero] )
      end do

    case('volumetric')
      call nc_putvar_by_name(ncid    = ncid_intermediate, &
                             varname = 'K_x',             & 
                             values  = real(K_x(ielement, :), kind=sp),    &
                             start   = [ielement, 1],       &
                             count   = [1, parameters%nkernel] )
      call nc_putvar_by_name(ncid    = ncid_intermediate, &
                             varname = 'Var',             & 
                             values  = real(Var(ielement, :), kind=sp),    &
                             start   = [ielement, 1],       &
                             count   = [1, parameters%nkernel] )
      call nc_putvar_by_name(ncid    = ncid_intermediate, &
                             varname = 'Bg_Model',        & 
                             values  = real(Bg_Model(ielement, :), kind=sp),&
                             start   = [ielement, 1],        &
                             count   = [1, nmodel_parameters] )
      call nc_putvar_by_name(ncid    = ncid_intermediate, &
                             varname = 'Het_Model',        & 
                             values  = real(Het_Model(ielement, :), kind=sp),&
                             start   = [ielement, 1],        &
                             count   = [1, nmodel_parameters_hetero] )

    end select ! int_type

    call nc_putvar_by_name(ncid    = ncid_intermediate, &
                           varname = 'niterations',        & 
                           values  = niterations(ielement, :),&
                           start   = [ielement, 1],        &
                           count   = [1, parameters%nkernel] )
  end do

  call nc_putvar_by_name(ncid    = ncid_intermediate, &
                         varname = 'element_proc',        & 
                         values  = element_proc)
  
  iclockold = tick(id=id_dump, since=iclockold)


end subroutine dump_intermediate
!-----------------------------------------------------------------------------------------

end module
!=========================================================================================
