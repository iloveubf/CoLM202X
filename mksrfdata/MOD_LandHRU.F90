#include <define.h>

#ifdef CATCHMENT 

MODULE MOD_LandHRU

   !------------------------------------------------------------------------------------
   ! DESCRIPTION:
   !
   !    Build pixelset "landhru".
   !
   !    In CoLM, the global/regional area is divided into a hierarchical structure:
   !    1. If GRIDBASED or UNSTRUCTURED is defined, it is
   !       ELEMENT >>> PATCH
   !    2. If CATCHMENT is defined, it is
   !       ELEMENT >>> HRU >>> PATCH
   !    If Plant Function Type classification is used, PATCH is further divided into PFT.
   !    If Plant Community classification is used,     PATCH is further divided into PC.
   ! 
   !    "landhru" refers to pixelset HRU.
   !
   ! Created by Shupeng Zhang, May 2023
   !------------------------------------------------------------------------------------

   USE MOD_Precision
   USE MOD_Pixelset
   USE MOD_Grid
   IMPLICIT NONE

   ! ---- Instance ----
   INTEGER :: numhru
   TYPE(grid_type)     :: ghru
   TYPE(pixelset_type) :: landhru
   
   TYPE(subset_type) :: basin_hru

CONTAINS

   ! -------------------------------
   SUBROUTINE landhru_build ()

      USE MOD_Precision
      USE MOD_SPMD_Task
      USE MOD_Utils
      USE MOD_Block
      USE MOD_Grid
      USE MOD_DataType
      USE MOD_Mesh
      USE MOD_LandElm
      USE MOD_CatchmentDataReadin
      USE MOD_Namelist
      USE MOD_AggregationRequestData

      IMPLICIT NONE

      ! Local Variables
      INTEGER :: maxhrutype
      TYPE (block_data_int32_2d) :: hrudata
      INTEGER :: ie, iblkme, iblk, jblk, npxl, ipxl
      INTEGER, allocatable :: types(:), order(:), ibuff(:)
      INTEGER, allocatable :: eindex_tmp(:), settyp_tmp(:), ipxstt_tmp(:), ipxend_tmp(:), ielm_tmp(:)
      INTEGER :: nhru_glb

#ifdef USEMPI
      CALL mpi_barrier (p_comm_glb, p_err)
#endif

      IF (p_is_master) THEN
         write(*,'(A)') 'Making land hydro units :'
      ENDIF

      IF (p_is_io) THEN
         CALL allocate_block_data (ghru, hrudata)
      ENDIF

      CALL catchment_data_read (DEF_path_catchment_data, 'ihydrounit2d', ghru, hrudata, &
         catchment_data_in_one_file)

      IF (p_is_io) THEN
         maxhrutype = -1
         DO iblkme = 1, gblock%nblkme
            iblk = gblock%xblkme(iblkme)
            jblk = gblock%yblkme(iblkme)
            IF (allocated(hrudata%blk(iblk,jblk)%val)) THEN
               maxhrutype = max(maxhrutype, maxval(hrudata%blk(iblk,jblk)%val))
            ENDIF
         ENDDO

         maxhrutype = maxhrutype + 1 ! index starting from 0
      ENDIF

#ifdef USEMPI
      IF (p_is_io) THEN
         CALL mpi_allreduce (MPI_IN_PLACE, maxhrutype, 1, MPI_INTEGER, MPI_MAX, p_comm_io, p_err)
         
         IF (p_iam_io == 0) THEN
            call mpi_send (maxhrutype, 1, MPI_INTEGER, p_root, mpi_tag_mesg, p_comm_glb, p_err) 
         ENDIF
      ENDIF
      IF (p_is_master) THEN
         call mpi_recv (maxhrutype, 1, MPI_INTEGER, p_address_io(0), &
            mpi_tag_mesg, p_comm_glb, p_stat, p_err)
      ENDIF
      
      CALL mpi_bcast (maxhrutype, 1, MPI_INTEGER, p_root, p_comm_glb, p_err)
#endif

#ifdef USEMPI
      IF (p_is_io) THEN 
         CALL aggregation_data_daemon (ghru, data_i4_2d_in1 = hrudata)
      ENDIF
#endif

      IF (p_is_worker) THEN

         allocate (eindex_tmp (numelm*maxhrutype))
         allocate (ipxstt_tmp (numelm*maxhrutype))
         allocate (ipxend_tmp (numelm*maxhrutype))
         allocate (settyp_tmp (numelm*maxhrutype))
         allocate (ielm_tmp   (numelm*maxhrutype))

         numhru = 0

         DO ie = 1, numelm
         
            npxl = mesh(ie)%npxl 
            
            allocate (types (1:npxl))

            CALL aggregation_request_data (landelm, ie, ghru, &
               data_i4_2d_in1 = hrudata, data_i4_2d_out1 = ibuff)

            types = ibuff
               
            allocate (order (1:npxl))
            order = (/ (ipxl, ipxl = 1, npxl) /)

            CALL quicksort (npxl, types, order)
               
            mesh(ie)%ilon(1:npxl) = mesh(ie)%ilon(order)
            mesh(ie)%ilat(1:npxl) = mesh(ie)%ilat(order)
            
            DO ipxl = 1, npxl
               IF (ipxl == 1) THEN
                  numhru = numhru + 1 
                  eindex_tmp (numhru) = mesh(ie)%indx
                  settyp_tmp (numhru) = types(ipxl)
                  ipxstt_tmp (numhru) = ipxl
                  ielm_tmp   (numhru) = ie
               ELSEIF (types(ipxl) /= types(ipxl-1)) THEN
                  ipxend_tmp(numhru) = ipxl - 1

                  numhru = numhru + 1
                  eindex_tmp (numhru) = mesh(ie)%indx
                  settyp_tmp (numhru) = types(ipxl)
                  ipxstt_tmp (numhru) = ipxl
                  ielm_tmp   (numhru) = ie
               ENDIF
            ENDDO
            ipxend_tmp(numhru) = npxl
            
            deallocate (ibuff)
            deallocate (types)
            deallocate (order)

         ENDDO

         allocate (landhru%eindex (numhru))
         allocate (landhru%settyp (numhru))
         allocate (landhru%ipxstt (numhru))
         allocate (landhru%ipxend (numhru))
         allocate (landhru%ielm   (numhru))
         
         landhru%eindex = eindex_tmp (1:numhru)  
         landhru%settyp = settyp_tmp (1:numhru)  
         landhru%ipxstt = ipxstt_tmp (1:numhru)
         landhru%ipxend = ipxend_tmp (1:numhru)
         landhru%ielm   = ielm_tmp   (1:numhru)  

         deallocate (settyp_tmp)
         deallocate (ipxstt_tmp)
         deallocate (ipxend_tmp)
         deallocate (eindex_tmp)
         deallocate (ielm_tmp  )

#ifdef USEMPI
         CALL aggregation_worker_done ()
#endif
      ENDIF

      landhru%nset = numhru
      CALL landhru%set_vecgs 
         
#ifdef USEMPI
      IF (p_is_worker) THEN
         CALL mpi_reduce (numhru, nhru_glb, 1, MPI_INTEGER, MPI_SUM, p_root, p_comm_worker, p_err)
         IF (p_iam_worker == 0) THEN
            write(*,'(A,I12,A)') 'Total: ', nhru_glb, ' hydro units.'
         ENDIF
      ENDIF

      CALL mpi_barrier (p_comm_glb, p_err)
#else
      write(*,'(A,I12,A)') 'Total: ', numhru, ' hydro units.'
#endif

   END SUBROUTINE landhru_build
   
END MODULE MOD_LandHRU
#endif
