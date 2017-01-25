! ********************************************************************************************
! WABBIT
! ============================================================================================
! name: main.f90
! version: 0.4
! author: msr
!
! main program, init all data, start time loop, output on screen during program run
!
! = log ======================================================================================
!
! 04/11/16 - switch to v0.4
! 23/11/16 - use computing time array for simple performance tests
! 07/12/16 - now uses heavy work data array
! ********************************************************************************************

program main

!---------------------------------------------------------------------------------------------
! modules

    use mpi
    ! global parameters
    use module_params
    ! debug module
    use module_debug
    ! init data module
    use module_init
    ! mesh manipulation subroutines
    use module_mesh
    ! IO module
    use module_IO
    ! time step module
    use module_time_step

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    ! MPI error variable
    integer(kind=ik)                    :: ierr
    ! process rank
    integer(kind=ik)                    :: rank
    ! number of processes
    integer(kind=ik)                    :: number_procs

    ! cpu time variables for running time calculation
    real(kind=rk)                       :: t0, t1

    ! user defined parameter structure
    type (type_params)                  :: params

    ! light data array  -> line number = ( 1 + proc_rank ) * heavy_data_line_number
    !                   -> column(1:max_treelevel): block treecode, treecode -1 => block is inactive
    !                   -> column(max_treelevel+1): treecode length = mesh level
    !                   -> column(max_treelevel+2):   refinement status (-1..coarsen / 0...no change / +1...refine)
    integer(kind=ik), allocatable       :: lgt_block(:, :)

    !                   -> dim 1: x coord   ( 1:number_block_nodes+2*number_ghost_nodes )
    !                   -> dim 2: y coord   ( 1:number_block_nodes+2*number_ghost_nodes )
    !                   -> dim 3: data type ( field_1, 2:number_data_fields+1)
    ! heavy data array  -> dim 4: block id  ( 1:number_blocks )
    !           field_1 (to save mixed data):   line 1: x coordinates
    !                                           line 2: y coordinates
    real(kind=rk), allocatable          :: hvy_block(:, :, :, :)

    !                   -> dim 1: x coord   ( 1:number_block_nodes+2*number_ghost_nodes )
    !                   -> dim 2: y coord   ( 1:number_block_nodes+2*number_ghost_nodes )
    !                   -> dim 3: data type ( old data, k1, k2, k3, k4 )
    ! heavy work array  -> dim 4: block id  ( 1:number_blocks )
    real(kind=rk), allocatable          :: hvy_work(:, :, :, :)

    ! neighbor array (heavy data) -> number_lines   = number_blocks (correspond to heavy data id)
    !                             -> number_columns = 16 (...different neighbor relations:
    ! '__N', '__E', '__S', '__W', '_NE', '_NW', '_SE', '_SW', 'NNE', 'NNW', 'SSE', 'SSW', 'ENE', 'ESE', 'WNW', 'WSW' )
    !         saved data -> -1 ... no neighbor
    !                    -> light data id in corresponding column
    integer(kind=ik), allocatable       :: hvy_neighbor(:,:)

    ! list of active blocks (light data)
    integer(kind=ik), allocatable       :: lgt_active(:)
    ! number of active blocks (light data)
    integer(kind=ik)                    :: lgt_n

    ! list of active blocks (heavy data)
    integer(kind=ik), allocatable       :: hvy_active(:)
    ! number of active blocks (heavy data)
    integer(kind=ik)                    :: hvy_n

    ! time loop variables
    real(kind=rk)                       :: time, output_time
    integer(kind=ik)                    :: iteration

!---------------------------------------------------------------------------------------------
! interfaces

!---------------------------------------------------------------------------------------------
! variables initialization

    ! init time loop
    time          = 0.0_rk
    iteration     = 0

!---------------------------------------------------------------------------------------------
! main body

    ! init mpi
    call MPI_Init(ierr)
    ! determinate process rank
    call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
    ! determinate process number
    call MPI_Comm_size(MPI_COMM_WORLD, number_procs, ierr)

    ! cpu start time
    call cpu_time(t0)

    ! output MPI status
    if (rank==0) then
        write(*,'(80("_"))')
        write(*, '("MPI: using ", i5, " processes")') number_procs
    end if

    ! initializing data
    call init_data( params, lgt_block, hvy_block, hvy_work, hvy_neighbor, lgt_active, hvy_active )

    ! create lists of active blocks (light and heavy data)
    call create_lgt_active_list( lgt_block, lgt_active, lgt_n )
    call create_hvy_active_list( lgt_block, hvy_active, hvy_n )

    ! update neighbor relations
    call update_neighbors( params, lgt_block, hvy_neighbor, lgt_active, lgt_n, hvy_active, hvy_n )

    ! save start data
    call save_data( iteration, time, params, lgt_block, hvy_block, hvy_neighbor, lgt_active, lgt_n )

    ! main time loop
    do while ( time < params%time_max )

        iteration = iteration + 1

        ! refine everywhere
        if ( params%adapt_mesh ) call refine_everywhere( params, lgt_block, hvy_block, lgt_active, lgt_n, hvy_active, hvy_n )

        ! update lists of active blocks (light and heavy data)
        call create_lgt_active_list( lgt_block, lgt_active, lgt_n )
        call create_hvy_active_list( lgt_block, hvy_active, hvy_n )

        ! update neighbor relations
        call update_neighbors( params, lgt_block, hvy_neighbor, lgt_active, lgt_n, hvy_active, hvy_n )

        ! advance in time
        call time_step_RK4( time, params, lgt_block, hvy_block, hvy_work, hvy_neighbor, hvy_active, hvy_n )

        ! adapt the mesh
        if ( params%adapt_mesh ) call adapt_mesh( params, lgt_block, hvy_block, hvy_neighbor, lgt_active, lgt_n, hvy_active, hvy_n  )

        ! output on screen
        if (rank==0) then
            write(*,'(80("-"))')
            write(*, '("RUN: iteration=",i5,3x," time=",f10.6,3x," active blocks=",i7)') iteration, time, lgt_n

        end if

        ! write data to disk
        if (modulo(iteration, params%write_freq) == 0) then
          call save_data( iteration, time, params, lgt_block, hvy_block, hvy_neighbor, lgt_active, lgt_n )
          output_time = time
        endif

        ! debug info
        if ( params%debug ) then
            ! sum and reset times and calls
            debug%comp_time(:,3) = debug%comp_time(:,3) + debug%comp_time(:,1)
            debug%comp_time(:,4) = debug%comp_time(:,4) + debug%comp_time(:,2)
            ! write debug infos to file
            call write_debug_times( iteration )
            ! reset loop values
            debug%comp_time(:,1) = 0.0_rk
            debug%comp_time(:,2) = 0.0_rk

        end if

    end do

    ! last timestep is very small
    if ( abs(output_time-time) < 1e-10 ) output_time = time

    ! save end field to disk, only if timestep is not saved allready
    if ( output_time /= time ) call save_data( iteration, time, params, lgt_block, hvy_block, hvy_neighbor, lgt_active, lgt_n )

    ! MPI Barrier before program ends
    call MPI_Barrier(MPI_COMM_WORLD, ierr)

    ! computing time output on screen
    call cpu_time(t1)
    if (rank==0) then
        write(*,'(80("_"))')
        write(*,'("END: cpu-time = ",f16.4, " s")')  t1-t0
    end if

    ! end mpi
    call MPI_Finalize(ierr)

end program main