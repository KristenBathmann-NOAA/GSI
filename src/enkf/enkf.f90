module enkf
!$$$  module documentation block
!
! module: enkf                         Update model state variables and
!                                      bias coefficients with the
!                                      serial EnKF.
!
! prgmmr: whitaker         org: esrl/psd               date: 2009-02-23
!
! abstract: Updates the model state using the serial EnKF.  If the namelist
!  parameter deterministic is .true., the serial ensemble square root
!  filter described by Whitaker and Hamill (2002, MWR, p. 1913-1924) is used.
!  If deterministic is .false., the serial EnKF with perturbed obs 
!  is used. If deterministic=.false, and sortinc=.true., the updated
!  observation variable ensemble members are paired with the prior members
!  so as to reduce the value of the update increments, following 
!  Anderson (2003, MWR, p. 634-642).  By "serial", we mean that observations
!  are processed individually, one at a time.  The order that observations
!  are assimilated can be controlled by the namelist parameter iassim_order.
!  iassim_order=0 means assimilate obs in the order they were read in, 
!  iassim_order=1 means shuffle the obs randomly before assimilating,
!  and iassim_order=2 means assimilate in order of predicted obervation variance
!  reduction. Note that the predicted variance reduction is based on the
!  original background observation variance, and does not include the effect
!  of the assimilation of other observations.
!
!  The EnKF update is done in parallel using the algorithm described
!  by Anderson and Collins (2007, J. of Atm. & Oceanic Tech., p. 1452-1463).
!  In this algorithm, both the model state variables and the observation priors
!  (the predicted observation variable ensemble members) are updated so as to
!  avoid recomputing the forward operator after each observation is assimilated.
!
!  After the observation variables are updated, the bias coefficients update is done
!  using update_biascorr from module radbias.  This update is done via a
!  matrix inversion using all the observations at once, and a static (diagonal)
!  background error covariance matrix.  If the namelist parameter numiter is >
!  1, this process is repeated numiter times, with each observation variable update using
!  the latest estimate of the bias correction coefficients and each bias
!  coefficient update using the latest estimate of the observation increment
!  (observation minus ensemble mean observation variable).  The model state
!  variables are only updated during the last iteration.  After the update is
!  complete, the variables anal_chunk and ensmean_chunk (from module statevec)
!  contain the updated model state ensemble perturbations and ensemble mean,
!  and predx (from module radinfo) contains the updated bias coefficients.
!  obfit_post and obsprd_post contain the observation increments and observation
!  variable variance.
!
!  Covariance localization is used in the state update to limit the impact 
!  of observations to a specified distance from the observation in the
!  horizontal and vertical.  These distances can be set separately in the
!  NH, tropics and SH, and in the horizontal, vertical and time dimensions,
!  using the namelist parameters  corrlengthnh, corrlengthtr, corrlengthsh,
!  lnsigcutoffnh, lnsigcutofftr, lnsigcutoffsh (lnsigcutoffsatnh,
!  lnsigcutoffsattr, lnsigcutoffsatsh for satellite obs, similar for ps obs)
!  obtimelnh, obtimeltr, obtimelsh. The length scales should be given in km for the
!  horizontal, hours for time, and 'scale heights' (units of -log(p/pref)) in the
!  vertical. The function used for localization (function taper)
!  is imported from module covlocal. Localization requires that
!  every observation have an associated horizontal, vertical and temporal location.
!  For satellite radiance observations the vertical location is given by
!  the maximum in the weighting function associated with that sensor/channel/
!  background state (this computation, along with the rest of the forward
!  operator calcuation, is performed by a separate program using the GSI
!  forward operator code).  Since all the observation variable ensemble
!  members often cannot fit in memory, they are saved in a temp file by 
!  module readobs, and only those needed on this task are read in by
!  subroutine enkf_update.
!
!  Adaptive observation thinning can be done via the parameter paoverpb_thresh.
!  If this parameter >= 1 (1 is the default) no thinning is done.  If < 1, an 
!  observation is not assimilated unless it will reduce the observation
!  variable ensemble variance by paoverpb_thresh (e.g. if paoverpb_thresh = 0.9,
!  only obs that will reduce the variance by 10% will be assimilated).
!
! Public Subroutines:
!  enkf_update: performs the EnKF update (calls update_biascorr to perform
!   the bias coefficient update.  The EnKF/bias coefficient update is 
!   iterated numiter times (parameter numiter from module params).
!
! Public Variables: None
!
! Modules Used: kinds, constants, params, covlocal, mpisetup, loadbal, statevec,
!               kdtree2_module, enkf_obsmod, radinfo, radbias, gridinfo
!
! program history log:
!   2009-02-23:  Initial version.
!   2016-02-01:  Ensure posterior perturbation mean remains zero.
!
! attributes:
!   language: f95
!
!$$$

use mpisetup
use covlocal, only:  taper
use kinds, only: r_double,i_kind,r_single,r_single
use kdtree2_module, only: kdtree2_r_nearest, kdtree2_result
use loadbal, only: numobsperproc, numptsperproc, indxproc_obs, iprocob, &
                   indxproc, lnp_chunk, kdtree_obs, kdtree_grid, &
                   ensmean_obchunk, indxob_chunk, oblnp_chunk, nobs_max, &
                   obtime_chunk, grdloc_chunk, obloc_chunk, &
                   npts_max, anal_obchunk_prior
use statevec, only: ensmean_chunk, anal_chunk, ensmean_chunk_prior
use enkf_obsmod, only: oberrvar, ob, ensmean_ob, obloc, oblnp, &
                  nobstot, nobs_conv, nobs_oz, nobs_sat,&
                  obfit_prior, obfit_post, obsprd_prior, obsprd_post, obtime,&
                  obtype, oberrvarmean, numobspersat, deltapredx, biaspreds,&
                  biasprednorm, oberrvar_orig, probgrosserr, prpgerr,&
                  corrlengthsq,lnsigl,obtimel,obloclat,obloclon,obpress,stattype
use constants, only: pi, one, zero
use params, only: sprd_tol, paoverpb_thresh, ndim, datapath, nanals,&
                  iassim_order,sortinc,deterministic,numiter,nlevs,nvars,&
                  zhuberleft,zhuberright,varqc,lupd_satbiasc,huber,univaroz,&
                  covl_minfact,covl_efold,nbackgrounds,nhr_anal,fhr_assim
use radinfo, only: npred,nusis,nuchan,jpch_rad,predx
use radbias, only: apply_biascorr, update_biascorr
use gridinfo, only: nlevs_pres,index_pres,nvarozone
use sorting, only: quicksort, isort

implicit none

private
public :: enkf_update

contains

subroutine enkf_update()
use random_normal, only : rnorm, set_random_seed
! serial EnKF update.

! local variables.
integer(i_kind) nob,nob1,nob2,nob3,npob,nf,nf2,ii,nobx,nskip,&
                niter,i,nrej,npt,nuse,ncount,nb
integer(i_kind) indxens1(nanals),indxens2(nanals)
real(r_single) hxpost(nanals),hxprior(nanals),hxinc(nanals),&
             dist,lnsig,obt,&
             sqrtoberr,corrlengthinv,lnsiglinv,obtimelinv
real(r_single) corrsqr,covl_fact
real(r_double) :: t1,t2,t3,t4,t5,t6,tbegin,tend
real(r_single) kfgain,hpfht,hpfhtoberrinv,r_nanals,r_nanalsm1,hpfhtcon
real(r_single) anal_obtmp(nanals),obinc_tmp,obens(nanals),obganl(nanals)
real(r_single) normdepart, pnge, width
real(r_single) buffer(nanals+2)
real(r_single),allocatable, dimension(:,:) :: anal_obchunk
real(r_single),dimension(nobstot):: oberrvaruse
real(r_single) r,paoverpb
real(r_single) taper1,taper3
real(r_single),allocatable, dimension(:) :: rannum,corrlengthsq_orig,lnsigl_orig
integer(i_kind), allocatable, dimension(:) :: indxassim,iskip,indxassim2,indxassim3
real(r_single), allocatable, dimension(:) :: buffertmp,taper_disob,taper_disgrd
real(r_single), allocatable, dimension(:) :: paoverpb_save
real(r_single), allocatable, dimension(:) :: paoverpb_min, paoverpb_min1, paoverpb_chunk
integer(i_kind) ierr
! kd-tree search results
type(kdtree2_result),dimension(:),allocatable :: sresults1,sresults2 
integer(i_kind) nanal,nn,nnn,nobm,nsame,nn1,nn2
real(r_single),dimension(nlevs_pres):: taperv
logical lastiter, kdgrid, kdobs

! allocate temporary arrays.
allocate(anal_obchunk(nanals,nobs_max))
allocate(sresults1(numptsperproc(nproc+1)),taper_disgrd(numptsperproc(nproc+1)))
allocate(sresults2(numobsperproc(nproc+1)),taper_disob(numobsperproc(nproc+1)))
allocate(buffertmp(nobstot))
! index array that controls assimilation order
allocate(indxassim(nobstot),iskip(nobstot))
allocate(paoverpb_save(nobstot))
allocate(corrlengthsq_orig(nobstot),lnsigl_orig(nobstot))

! define a few frequently used parameters
r_nanals=one/float(nanals)
r_nanalsm1=one/float(nanals-1)

! default is to assimilate in order they are read in.

do nob=1,nobstot
   indxassim(nob) = nob
end do

if (iassim_order == 1) then
  ! create random index array so obs are assimilated in random order.
  if (nproc == 0) then
      print *,'assimilate obs in random order'
      allocate(rannum(nobstot))
      call set_random_seed(0, nproc)
      call random_number(rannum)
      call quicksort(nobstot,rannum,indxassim)
      deallocate(rannum)
  end if
  call mpi_bcast(indxassim,nobstot,mpi_integer,0, &
       mpi_comm_world,ierr)
else if (iassim_order .eq. 2) then
  if (nproc .eq. 0) print *,'assimilate obs in order of increasing HPaHT/HPbHT'
  allocate(paoverpb_chunk(numobsperproc(nproc+1)))
  allocate(indxassim2(nobstot),indxassim3(nobstot))
  allocate(paoverpb_min(2),paoverpb_min1(2))
  ! don't try to get all the obs - stop when paoverpb
  ! very close to 1.0.  If paoverpb_thresh is set to 1.0,
  ! there are precision issues in the sorting, and duplicated
  ! are found (resulting in obs being assimlated more than once).
  if (paoverpb_thresh .gt. 0.999) paoverpb_thresh = 0.999
  ! if obs to be assimilated in order of increasing HPaHT/HPbHT,
  ! paoverpb_chunk holds latest estimate of obsdprd_post on each task.
  do nob=1,numobsperproc(nproc+1)
     nob1 = indxproc_obs(nproc+1,nob)
     paoverpb_chunk(nob) = oberrvar(nob1)/(oberrvar(nob1)+obsprd_prior(nob1))
  enddo
  do nob=1,nobstot
      indxassim2(nob) = nob
  enddo
  indxassim = 0
else
  if (nproc .eq. 0) print *,'assimilate obs in order they were read in'
end if

! initialize some arrays with first-guess values.
obfit_post(1:nobstot) = obfit_prior(1:nobstot)
obsprd_post(1:nobstot) = obsprd_prior(1:nobstot)
anal_obchunk = anal_obchunk_prior
corrlengthsq_orig = corrlengthsq
lnsigl_orig = lnsigl

! Check to see if kdtree structures are associated
kdgrid=associated(kdtree_grid)
kdobs=associated(kdtree_obs)

do niter=1,numiter

  lastiter = niter == numiter
  ! apply bias correction with latest estimate of bias coeffs.
  ! (already done for first iteration)
  if (nobs_sat > 0 .and. niter > 1 ) call apply_biascorr()

  ! reset first guess perturbations at start of each iteration.
  nrej=0
  nsame=0
  anal_obchunk = anal_obchunk_prior
  ! ensmean_ob is updated with latest bias coefficient perturbations.
  ! nob1 is the index of the obs to be processed on this rank
  ! nob2 maps nob1 to 1:nobstot array (nob)
  do nob1=1,numobsperproc(nproc+1)
     nob2 = indxproc_obs(nproc+1,nob1)
     ensmean_obchunk(nob1) = ensmean_ob(nob2)
  enddo
! reset ob error to account for gross errors 
  if (niter > 1 .and. varqc) then
    if (huber) then ! "huber norm" QC
      do nob=1,nobstot
        normdepart = obfit_post(nob)/sqrt(oberrvar(nob))
        ! depends of 2 parameters: zhuberright, zhuberleft.
        if (normdepart < -zhuberleft) then
           pnge = zhuberleft/abs(normdepart)
        else if (normdepart > zhuberright) then
           pnge = zhuberright/abs(normdepart)
        else
           pnge = one
        end if
        ! eqn 17 in Dharssi, Lorenc and Inglesby
        ! divide ob error by prob of gross error not occurring.
        oberrvaruse(nob) = oberrvar(nob)/pnge
        ! pnge is the prob that the ob *does not* contain a gross error.
        ! assume rejected if prob of gross err > 50%.
        probgrosserr(nob) = one-pnge
        if (probgrosserr(nob) > 0.5_r_single) then 
           nrej=nrej+1
        endif
      end do
    else ! "flat-tail" QC.
      do nob=1,nobstot
        ! original form, gross error cutoff a multiple of ob error st dev.
        ! here gross err cutoff proportional to ensemble spread plus ob error
        ! Dharssi, Lorenc and Inglesby eqn (1) a = grosserrw*sqrt(S+R) 
        width = sprd_tol*sqrt(obsprd_prior(nob)+oberrvar(nob))
        pnge = prpgerr(nob)*sqrt(2.*pi*oberrvar(nob))/((one-prpgerr(nob))*(2.*width))
        normdepart = obfit_post(nob)/sqrt(oberrvar(nob))
        pnge = one - (pnge/(pnge+exp(-normdepart**2/2._r_single)))
        ! eqn 17 in Dharssi, Lorenc and Inglesby
        ! divide ob error by prob of gross error not occurring.
        oberrvaruse(nob) = oberrvar(nob)/pnge
        ! pnge is the prob that the ob *does not* contain a gross error.
        ! assume rejected if prob of gross err > 50%.
        probgrosserr(nob) = one-pnge
        if (probgrosserr(nob) > 0.5_r_single) then 
           nrej=nrej+1
        endif
      end do
    endif
  else
    do nob=1,nobstot
      oberrvaruse(nob) = oberrvar(nob)
    end do
  end if

  if (niter == 1) iskip = 0
  nobm = 1
  ncount = 0
  t2 = zero
  t3 = zero
  t4 = zero
  t5 = zero
  t6 = zero
  nf    = 0
  nf2   = 0
  tbegin = mpi_wtime()
  ! loop over 'good' obs.
  obsloop: do nobx=1,nobstot

      t1 = mpi_wtime()

      ! which ob to assimilate next?
      if (iassim_order == 2) then
         if (niter == 1) then
            ! find ob with min HPaHT/HPbHT
            nob1 = minloc(paoverpb_chunk,1)
            paoverpb_min1(1) = paoverpb_chunk(nob1)
            paoverpb_min1(2) = indxproc_obs(nproc+1,nob1)
            call mpi_allreduce(paoverpb_min1,paoverpb_min,1,&
                               mpi_2real,mpi_minloc,mpi_comm_world,ierr)
            if (paoverpb_min(1) >= paoverpb_thresh) then
                if (nproc .eq. 0) &
                print *,'exiting obsloop after ',nobx,' obs processed' 
                nob1 = count(indxassim2 /= 0)
                if (nobx-1+nob1 /= nobstot) then
                    if (nproc .eq. 0) then
                       print *,'error: not all obs accounted for!'
                       print *,'count indxassim2 nonzero',nob1
                       print *,'nobx,nobstot,nobx+nobstot',nobx,nobstot,nobx-1+nob1
                    endif
                    call stop2(91)
                endif
                ! fill rest of indxassim array with un-assimilated obs
                indxassim(nobx:nobstot) = pack(indxassim2,indxassim2 /= 0)
                do nob=nobx,nobstot
                   nob1 = indxassim(nob)
                   paoverpb_save(nob1) = paoverpb_thresh + tiny(paoverpb_thresh)
                   iskip(nob1) = 1
                enddo
                ! check to see that all obs accounted for.
                if (nproc .eq. 0) then
                   do nob=1,nobstot
                      indxassim2(nob) = nob
                   enddo
                   indxassim3 = indxassim
                   call isort(indxassim3, nobstot)
                   ! if indxassim2 != indxassim3 there are duplicates
                   nob1 = count(indxassim2-indxassim3 /= 0)
                   if (nob1 /= 0) then
                      if (nproc .eq. 0) then
                         print *,'error: not all obs accounted for!'
                         print *,'count nonzero',nob1
                      endif
                      call stop2(92)
                   endif
                endif
                exit obsloop
            endif 
            nob = paoverpb_min(2); indxassim(nobx) = nob
            if (indxassim2(nob) == 0) then
               if (nproc .eq. 0) then
                  print *,'error: this ob already assimilated!'
                  print *,'nobx,nob,paoverpb',nobx,nob,paoverpb_min(1),oberrvaruse(nob)
               endif
               call stop2(93)
            else
               indxassim2(nob) = 0
            endif
         else ! niter > 1
            nob = indxassim(nobx)
         endif
      else
         nob = indxassim(nobx)
      endif

      npob = iprocob(nob) ! what task is this ob on?
  
      ! get ob priors, ob increment from that processor,
      ! send to other processors.
      if (nproc == npob) then
          nob1 = indxob_chunk(nob); 
          hpfht = sum(anal_obchunk(:,nob1)**2)*r_nanalsm1
          buffer(1:nanals) = anal_obchunk(:,nob1)
          buffer(nanals+1) = ob(nob)-ensmean_obchunk(nob1)
          buffer(nanals+2) = hpfht
      end if
      call mpi_bcast(buffer,nanals+2,mpi_real4,npob,mpi_comm_world,ierr)

      t2 = t2 + mpi_wtime() - t1
      t1 = mpi_wtime()

      anal_obtmp = buffer(1:nanals)
      obinc_tmp = buffer(nanals+1)
      hpfht = buffer(nanals+2)

      hpfhtoberrinv=one/(hpfht+oberrvaruse(nob))
      paoverpb = oberrvar(nob)/(hpfht + oberrvar(nob))
      if (niter == 1) paoverpb_save(nob) = paoverpb

      if (paoverpb_save(nob) >= paoverpb_thresh .or. &
          oberrvaruse(nob) > 1.e10_r_single) then
          iskip(nob) = 1
          if (iassim_order == 2) then
             if (nproc .eq. 0) &
             print *,'exiting obsloop after ',nobx,' obs processed' 
             exit obsloop
          else
             cycle obsloop ! skip to next ob
          endif
      else
          iskip(nob) = 0
      end if

      if (deterministic) then
         ! EnSRF.
         obganl = -anal_obtmp/(one+sqrt(oberrvaruse(nob)*hpfhtoberrinv))
      else
         ! perturbed obs EnKF.
         sqrtoberr=sqrt(oberrvaruse(nob))
         do nanal=1,nanals
             obens(nanal) = sqrtoberr*rnorm()
         enddo
         ! make sure mean is zero
         obens = obens - sum(obens)*r_nanals
         if (sortinc) then
           ! To minimize regression errors, sort to minimize increments.
           ! ref - Anderson (2003) "A Least-Squares Framework for Ensemble Filtering"
           ! April issue, pages 634-642.
           kfgain = hpfht*hpfhtoberrinv
           hxprior = anal_obtmp
           hxpost = hxprior+kfgain*(obens-hxprior)
           call quicksort(nanals, hxprior, indxens1)
           call quicksort(nanals, hxpost, indxens2)
           do nanal=1,nanals
              hxinc(indxens1(nanal)) = hxpost(indxens2(nanal)) - hxprior(indxens1(nanal))
           end do
           ! re-order ob perturbations to minimize increments.
           obens = hxinc/kfgain + hxprior
         end if
         obganl = obens - anal_obtmp
      end if

      t3 = t3 + mpi_wtime() - t1
      t1 = mpi_wtime()

      if (covl_minfact < 0.99) then
! modify localization based on HPaHT/HPbHT
         covl_fact = 1. - exp( -((1.-paoverpb_save(nob))/covl_efold) )
         if (covl_fact .lt. covl_minfact) covl_fact = covl_minfact
         corrlengthsq(nob) = (covl_fact*sqrt(corrlengthsq_orig(nob)))**2
         lnsigl(nob) = covl_fact*lnsigl_orig(nob)
      endif

      lnsiglinv = one/lnsigl(nob)
      corrsqr = corrlengthsq(nob)
      corrlengthinv=one/corrlengthsq(nob)
      lnsiglinv=one/lnsigl(nob)
      obtimelinv=one/obtimel(nob)
      hpfhtcon=hpfhtoberrinv*r_nanalsm1

!  Only need to recalculate nearest points when lat/lon is different
      if(nobx == 1 .or. &
         abs(obloclat(nob)-obloclat(nobm)) .gt. tiny(obloclat(nob)) .or. &
         abs(obloclon(nob)-obloclon(nobm)) .gt. tiny(obloclon(nob)) .or. &
         abs(corrlengthsq(nob)-corrlengthsq(nobm)) .gt. tiny(corrlengthsq(nob))) then
       nobm=nob
       ! determine localization length scales based on latitude of ob.
       nf2=0
       if (lastiter) then
        ! search analysis grid points for those within corrlength of 
        ! ob being assimilated (using a kd-tree for speed).
        if (kdgrid) then
           call kdtree2_r_nearest(tp=kdtree_grid,qv=obloc(:,nob),r2=corrsqr,&
                nfound=nf2,nalloc=numptsperproc(nproc+1),results=sresults1)
        else
           ! use brute force search if number of grid points on this proc <= 3
           do npt=1,numptsperproc(nproc+1)
              r = sum( (obloc(:,nob)-grdloc_chunk(:,npt))**2, 1 )
              if (r < corrsqr) then
                  nf2 = nf2 + 1
                  sresults1(nf2)%idx = npt
                  sresults1(nf2)%dis = r
              end if     
           end do
        end if
       end if
       do nob1=1,nf2
          dist = sqrt(sresults1(nob1)%dis*corrlengthinv)
          taper_disgrd(nob1) = taper(dist)
       end do

       ! search ob priors for those within corrlength of the ob
       ! being assimilated (using a kd-tree for speed).
       nf = 0
       if (kdobs) then
         call kdtree2_r_nearest(tp=kdtree_obs,qv=obloc(:,nob),r2=corrsqr,&
              nfound=nf,nalloc=numobsperproc(nproc+1),results=sresults2)
       else
         ! use brute force search if number of obs on this proc <= 3
         do nob1=1,numobsperproc(nproc+1)
            r = sum( (obloc(:,nob)-obloc_chunk(:,nob1))**2, 1 )
            if (r < corrsqr) then
                nf = nf + 1
                sresults2(nf)%idx = nob1
                sresults2(nf)%dis = r
            end if     
         end do
       end if
       do nob1=1,nf
          ! ozone obs only affect ozone (if univaroz is .true.).
          nob2 = sresults2(nob1)%idx
          if (univaroz .and. obtype(nob)(1:3) .eq. ' oz' .and. obtype(indxproc_obs(nproc+1,nob2))(1:3) .ne. ' oz') then
              taper_disob(nob1) = zero
          else
              dist = sqrt(sresults2(nob1)%dis*corrlengthinv)
              taper_disob(nob1) = taper(dist)
          endif
       end do
      else
        nsame=nsame+1
      end if

  
      t4 = t4 + mpi_wtime() - t1
      t1 = mpi_wtime()

      ! only need to update state variables on last iteration.
      if (univaroz .and. obtype(nob)(1:3) .eq. ' oz' .and. nvars .ge. nvarozone) then ! ozone obs only affect ozone
          nn1 = (nvarozone-1)*nlevs+1
          nn2 = nvarozone*nlevs
      else
          nn1 = 1
          nn2 = ndim
      end if
      if (nf2 > 0) then
!$omp parallel do schedule(dynamic,1) private(ii,i,nb,obt,nn,nnn,lnsig,kfgain,taper1,taperv)
          do ii=1,nf2 ! loop over nearby horiz grid points
             do nb=1,nbackgrounds ! loop over background time levels
             obt = abs(obtime(nob)-(nhr_anal(nb)-fhr_assim))
             taper3=taper(obt*obtimelinv)*hpfhtcon
             taper1=taper_disgrd(ii)*taper3
             i = sresults1(ii)%idx
             do nn=1,nlevs_pres
               lnsig = abs(lnp_chunk(i,nn)-oblnp(nob))
               if(lnsig < lnsigl(nob))then
                 taperv(nn)=taper1*taper(lnsig*lnsiglinv)
               else
                 taperv(nn)=-2._r_single      ! negative number is a flag to not use
               end if
             end do
             do nn=nn1,nn2
                nnn=index_pres(nn)
                if (taperv(nnn) > zero) then
                    ! gain includes covariance localization.
                    ! update all time levels
                    kfgain=taperv(nnn)*sum(anal_chunk(:,i,nn,nb)*anal_obtmp)
                    ! update mean.
                    ensmean_chunk(i,nn,nb) = ensmean_chunk(i,nn,nb) + kfgain*obinc_tmp
                    ! update perturbations.
                    anal_chunk(:,i,nn,nb) = anal_chunk(:,i,nn,nb) + kfgain*obganl(:)
                end if
             end do
          end do ! end loop over background time levels. 
          end do ! end loop over nearby horiz grid points
!$omp end parallel do
      end if ! if .not. lastiter or no close grid points

      t5 = t5 + mpi_wtime() - t1
      t1 = mpi_wtime()

      if (nf > 0) then
        ! find indices of 'close' obs.
!$omp parallel do  schedule(dynamic,1) private(nob1,nob2,nob3,lnsig,obt,kfgain)
        do nob1=1,nf
           ! Note: only really need to do obs that have not yet been processed unless sat data
           ! for bias correction update.
           nob2 = sresults2(nob1)%idx
           lnsig = abs(oblnp(nob)-oblnp_chunk(nob2))
           if (lnsig < lnsigl(nob) .and. taper_disob(nob1) > zero) then
             obt = abs(obtime(nob)-obtime_chunk(nob2))
             if (obt < obtimel(nob)) then
               ! gain includes covariance localization.
               kfgain = taper_disob(nob1)* &
                        taper(lnsig*lnsiglinv)*taper(obt*obtimelinv)* &
                        sum(anal_obchunk(:,nob2)*anal_obtmp)*hpfhtcon
               ! update mean.
               ensmean_obchunk(nob2) = ensmean_obchunk(nob2) + kfgain*obinc_tmp
               ! update perturbations.
               anal_obchunk(:,nob2) = anal_obchunk(:,nob2) + kfgain*obganl
               nob3 = indxproc_obs(nproc+1,nob2) ! index in 1,....,nobstot
               ! recompute ob space spread ratio  for unassimlated obs
               if (iassim_order == 2 .and. niter == 1) then
                 if (indxassim2(nob3) /= 0) then
                   paoverpb_chunk(nob2) = &
                   oberrvar(nob3)/(oberrvar(nob3)+&
                   sum(anal_obchunk(:,nob2)**2)*r_nanalsm1)
                 else
                   paoverpb_chunk(nob2) = 1.e10
                 endif
               endif
             end if
           end if
        end do
!$omp end parallel do

      end if ! no close obs.

      t6 = t6 + mpi_wtime() - t1
      ncount = ncount + 1

  end do obsloop ! loop over obs to assimilate

  ! make sure posterior perturbations still have zero mean.
  ! (roundoff errors can accumulate)
  !$omp parallel do schedule(dynamic) private(npt,nb,i)
  do npt=1,npts_max
     do nb=1,nbackgrounds
        do i=1,ndim
           anal_chunk(1:nanals,npt,i,nb) = anal_chunk(1:nanals,npt,i,nb)-&
           sum(anal_chunk(1:nanals,npt,i,nb),1)/r_nanals
        end do
     end do
  enddo
  !$omp end parallel do
  !$omp parallel do schedule(dynamic) private(nob)
  do nob=1,nobs_max
     anal_obchunk(1:nanals,nob) = anal_obchunk(1:nanals,nob)-&
     sum(anal_obchunk(1:nanals,nob),1)/r_nanals
  enddo
  !$omp end parallel do

  tend = mpi_wtime()
  if (nproc .eq. 0) then
      write(6,8003) niter,'timing on proc',nproc,' = ',tend-tbegin,t2,t3,t4,t5,t6,nrej

      nuse = 0; covl_fact = 0.
      do nob1=1,ncount
         nob = indxassim(nob1)
         if (iskip(nob) .ne. 1) then
            covl_fact = covl_fact + sqrt(corrlengthsq(nob)/corrlengthsq_orig(nob))
            nuse = nuse + 1
         endif
      enddo
      nskip = nobstot-nuse
      covl_fact = covl_fact/float(nuse)

      if (covl_fact < 0.99) print *,'mean covl_fact = ',covl_fact
      if (nskip > 0) print *,nskip,' out of',nobstot,'obs skipped,',nuse,' used'
      if (nsame > 0) print *,nsame,' out of', nobstot-nskip,' same lat/long'
      if (nrej >  0) print *,nrej,' obs rejected by varqc'
  endif
  8003  format(i2,1x,a14,1x,i5,1x,a3,6(f7.2,1x),i4)

  t1 = mpi_wtime()
! distribute the O-A stats to all processors.
  buffertmp=zero
  do nob1=1,numobsperproc(nproc+1)
    nob2=indxproc_obs(nproc+1,nob1)
    buffertmp(nob2) = ensmean_obchunk(nob1)
  end do
  call mpi_allreduce(buffertmp,obfit_post,nobstot,mpi_real4,mpi_sum,mpi_comm_world,ierr)
  obfit_post = ob - obfit_post
  if (nproc == 0) print *,'time to broadcast obfit_post = ',mpi_wtime()-t1,' secs, niter =',niter

  ! satellite bias correction update.
  if (nobs_sat > 0 .and. lupd_satbiasc) call update_biascorr(niter)

enddo ! niter loop

! distribute the HPaHT stats to all processors.
t1 = mpi_wtime()
buffertmp=zero
do nob1=1,numobsperproc(nproc+1)
  nob2=indxproc_obs(nproc+1,nob1)
  buffertmp(nob2) = sum(anal_obchunk(:,nob1)**2)*r_nanalsm1
end do
call mpi_allreduce(buffertmp,obsprd_post,nobstot,mpi_real4,mpi_sum,mpi_comm_world,ierr)
if (nproc == 0) print *,'time to broadcast obsprd_post = ',mpi_wtime()-t1

predx = predx + deltapredx ! add increment to bias coeffs.

! free local temporary arrays.
deallocate(taper_disob,taper_disgrd)
! these allocated in loadbal, no longer needed
deallocate(anal_obchunk); deallocate(anal_obchunk_prior)
deallocate(sresults1,sresults2)
deallocate(indxassim,buffertmp)
if (iassim_order == 2) then
   deallocate(paoverpb_chunk)
   deallocate(indxassim2,indxassim3)
   deallocate(paoverpb_min,paoverpb_min1)
endif
deallocate(paoverpb_save)
deallocate(corrlengthsq_orig,lnsigl_orig)

end subroutine enkf_update

end module enkf
