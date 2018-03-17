module statistics

  use globals
  implicit none

contains

  !----------------------------------------------------------------------------!

  subroutine mexha(sg, k)
    real, intent(in) :: sg
    real, intent(out) :: k(:,:)
    integer :: i,j

    do concurrent (i = 1:size(k,1), j = 1:size(k,2))
      k(i,j) = mexha0(i - real(size(k,1) + 1) / 2,   &
                      j - real(size(k,2) + 1) / 2, sg)
    end do

  contains

    elemental function mexha0(x,y,sg) result(yf)
      real, intent(in) :: x,y,sg
      real :: yf,k
      real(dp), parameter :: pi = 4 * atan(1d0)
      k = (x**2 + y**2) / (2 * sg**2)
      yf =  (1 - k)  / (pi * sg**4) * exp(-k)
    end function

  end subroutine


  !----------------------------------------------------------------------------!
  ! quickselect algorithm
  ! translated from: Numerical recipes in C

  function quickselect(arr, k) result(median)
    real, intent(inout) :: arr(:)
    real :: a, median
    integer, intent(in) :: k
    integer :: i, j, lo, hi, mid

    lo = 1
    hi = size(arr)

    main_loop: do
      if (hi <= lo+1) then

        if (hi == lo+1 .and. arr(hi) < arr(lo)) call swap(arr(lo),arr(hi))
        median = arr(k)
        exit main_loop

      else

        mid = (lo + hi) / 2
        call swap(arr(mid), arr(lo+1))
        if (arr(lo  ) > arr(hi  )) call swap(arr(lo  ), arr(hi  ))
        if (arr(lo+1) > arr(hi  )) call swap(arr(lo+1), arr(hi  ))
        if (arr(lo  ) > arr(lo+1)) call swap(arr(lo  ), arr(lo+1))

        i = lo + 1
        j = hi
        a = arr(lo + 1)

        inner: do
          do
            i = i + 1
            if (arr(i) >= a) exit
          end do
          do
            j = j - 1
            if (arr(j) <= a) exit
          end do
          if (j < i) exit inner
          call swap(arr(i), arr(j))
        end do inner

        arr(lo+1) = arr(j)
        arr(j) = a

        if (j >= k) hi = j - 1
        if (j <= k) lo = i
      end if
    end do main_loop

  contains

    elemental subroutine swap(a,b)
      real, intent(inout) :: a, b
      real :: c
      c = a
      a = b
      b = c
    end subroutine
  end function

  !----------------------------------------------------------------------------!

  subroutine outliers(im, sigma, niter, msk, mean, stdev)
    use ieee_arithmetic, only: ieee_is_normal

    real(sp), intent(in) :: im(:,:), sigma
    integer, intent(in) :: niter
    logical, intent(out) :: msk(:,:)
    real(sp), intent(out) :: mean, stdev
    integer :: i,nn

    msk(:,:) = ieee_is_normal(im)

    do i = 1, niter
      nn    = count(msk)
      mean  = sum(im, msk) / nn
      stdev = sqrt(sum((im - mean)**2, msk) / (nn - 1))

      msk = msk .and. (im >= mean - sigma * stdev) &
                .and. (im <= mean + sigma * stdev)

      ! if (cfg_verbose) write (0, '(I2, " / ", I2, 3X, I10, 2F10.1)') &
        ! i, niter, nn, mean, stdev

      if ( count(msk) == nn ) exit
    end do

  end subroutine

  !----------------------------------------------------------------------------!

end module
