module stacking

  use globals
  implicit none

contains

  !----------------------------------------------------------------------------!

  subroutine register_stars(im, lst)
    use convolutions, only: convol_fix
    use kernels, only: mexhakrn_alloc
    use findstar, only: aqfindstar, extended_source

    real(fp), intent(in), contiguous :: im(:,:)
    type(extended_source), intent(out), allocatable :: lst(:)
    real(fp), allocatable :: im2(:,:), krn(:,:)
    integer :: nstars

    krn = mexhakrn_alloc(2.3_fp)

    allocate(im2(size(im,1), size(im,2)))

    call convol_fix(im, krn, im2, 'r')
    call aqfindstar(im2, lst, limit = 256)
  end subroutine

  !----------------------------------------------------------------------------!

  pure function check_corners(tx, nx, ny) result(margin)
    use new_align, only: transform_t

    class(transform_t), intent(in) :: tx
    integer, intent(in) :: nx, ny
    real(fp) :: rx, ry, sx, sy
    integer :: margin

    rx = 0.5_fp * (nx - 1)
    ry = 0.5_fp * (ny - 1)

    margin = 0
    call tx % apply(-rx, -ry, sx, sy)
    margin = max(margin, ceiling(abs(abs(rx) - abs(sx))), ceiling(abs(abs(ry) - abs(sy))))
    call tx % apply( rx, -ry, sx, sy)
    margin = max(margin, ceiling(abs(abs(rx) - abs(sx))), ceiling(abs(abs(ry) - abs(sy))))
    call tx % apply( rx,  ry, sx, sy)
    margin = max(margin, ceiling(abs(abs(rx) - abs(sx))), ceiling(abs(abs(ry) - abs(sy))))
    call tx % apply(-rx,  ry, sx, sy)
    margin = max(margin, ceiling(abs(abs(rx) - abs(sx))), ceiling(abs(abs(ry) - abs(sy))))
  end function

  !----------------------------------------------------------------------------!

  subroutine normalize_offset_gain(buffer, margin)
    use statistics, only: linfit

    real(fp), intent(inout) :: buffer(:,:,:)
    integer, intent(in) :: margin
    
    real(fp) :: a, b
    real(fp), allocatable :: imref(:,:), xx(:), yy(:)
    logical, allocatable :: mask(:,:)
    integer :: i, sz(3), nstack

    sz = shape(buffer)
    nstack = sz(3)

    ! create mean frame to normalize to
    imref = sum(buffer, 3) / nstack

    ! create mask which excludes edges and the brigtenst pixels
    allocate(mask(sz(1), sz(2)))
    associate (m => margin)
      associate (imc => imref(1+m : sz(1)-m, 1+m : sz(2)-m))
        mask = imref < (minval(imc) + maxval(imc)) / 2
      end associate
      mask(:m, :) = .false.; mask(sz(1)-m+1:, :) = .false.
      mask(:, :m) = .false.; mask(:, sz(2)-m+1:) = .false.
    end associate

    ! pack it into 1-d array
    xx = pack(imref, mask)
    deallocate(imref)
    allocate(yy, mold = xx)

    do i = 1, nstack
      yy(:) = pack(buffer(:,:,i), mask)
      call linfit(xx, yy, a, b)
      write (stderr, '("NORM frame(",i2,") y = ",f5.3,"x + ",f7.1)') i, a, b
      buffer(:,:,i) = (buffer(:,:,i) - b) / a
    end do
  end subroutine

  !----------------------------------------------------------------------------!

  subroutine stack_and_write(strategy, method, frames, buffer, output_fn)
    use framehandling, only: image_frame_t

    character(len = *), intent(in) :: strategy, method, output_fn
    real(fp), intent(in) :: buffer(:,:,:)
    type(image_frame_t), intent(in) :: frames(:)
    type(image_frame_t) :: frame_out
    real(real64) :: t1, t2
    integer :: nstack
    character(len = 128) :: output_fn_clean

    nstack = size(buffer, 3)

    call frame_out % alloc_shape(size(buffer, 1), size(buffer, 2))

    call cpu_time(t1)
    call stack_buffer(method, buffer(:, :, 1:nstack), frame_out % data)
    call cpu_time(t2)
    print perf_fmt, 'stack', t2 - t1

    write_extra_info_hdr: block

      call frame_out % hdr % add_int('NSTACK', nstack)
      call frame_out % hdr % add_str('STCKMTD', method)
      if (strategy /= '') call frame_out % hdr % add_str('FRAMETYP', strategy)

      call propagate_average_value_real(frames(1:nstack), 'EXPTIME', frame_out)
      call propagate_average_value_real(frames(1:nstack), 'CCD-TEMP', frame_out)

    end block write_extra_info_hdr

    if ((strategy == 'bias' .or. strategy == 'dark') .and. nstack > 1) then
      estimate_noise: block
        real(fp) :: rms

        rms = estimate_differential_noise(buffer)

        write (*, '("RMS = ", f10.2)') rms
        call frame_out % hdr % add_float('RMS', real(rms))
        call frame_out % hdr % add_float('STACKRMS', real(rms / sqrt(1.0_fp * nstack)))
      end block estimate_noise
    end if

    write_stack: block
      if (output_fn == "") then
        if (strategy /= "") then
          output_fn_clean = trim(strategy) // ".fits"
        else
          output_fn_clean = "out.fits"
        end if
      else
        output_fn_clean = output_fn
      end if

      call frame_out % hdr % add('AQLVER', version)

      print '(a,a)', 'writing output file: ', trim(output_fn_clean)
      call frame_out % write_fits(output_fn_clean)

    end block write_stack

  end subroutine stack_and_write

  !----------------------------------------------------------------------------!

  subroutine stack_buffer(method, buffer, buffer_out)
    use statistics, only: quickselect, sigclip2

    real(fp), intent(in) :: buffer(:,:,:)
    real(fp), intent(out) :: buffer_out(:,:)
    character(len = *), intent(in) :: method
    integer :: i, j, nstack
    real(fp) :: a(size(buffer, 3))

    nstack = size(buffer, 3)

    select case (method)
    case ('m', 'median')
      !$omp parallel do private(i, j, a)
      do j = 1, size(buffer, 2)
        do i = 1, size(buffer, 1)
          a(:) = buffer(i, j, 1:nstack)
          ! forall (k = 1:nstack) a(k) = frames(k) % data(i, j)
          buffer_out(i, j) = quickselect(a(:), (nstack + 1) / 2)
        end do
      end do
      !$omp end parallel do
    case ('s', 'sigclip')
      !$omp parallel do private(i, j, a)
      do j = 1, size(buffer, 2)
        do i = 1, size(buffer, 1)
          ! forall (k = 1:nstack) a(k) = frames(k) % data(i, j)
          ! call sigclip2(a(:), frame_out % data(i, j))
          buffer_out(i, j) = sigclip2(buffer(i, j, 1:nstack), 3._fp)
        end do
      end do
      !$omp end parallel do
    case default
      buffer_out(:, :) = sum(buffer(:, :, 1:nstack), 3) / nstack
    end select
  end subroutine

  !----------------------------------------------------------------------------!

  subroutine propagate_average_value_real(frames, kw, frame_out)
    use framehandling, only: image_frame_t

    class(image_frame_t), intent(in) :: frames(:)
    class(image_frame_t), intent(inout) :: frame_out
    character(len = *) :: kw
    logical :: m(size(frames))
    real :: av
    integer :: i, errno

    m(:) = [ (frames(i) % hdr % has_key(kw), i = 1, size(frames)) ]
    if (count(m) > 0) then
      av = sum([ (merge(frames(i) % hdr % get_float(kw, errno), 0.0, m(i)), &
      &     i = 1, size(frames)) ]) / count(m)
      call frame_out % hdr % add_float(kw, av)
    end if
  end subroutine

  !----------------------------------------------------------------------------!

  pure function estimate_differential_noise(buffer) result(rms)
    use iso_fortran_env, only: int64
    real(fp), intent(in) :: buffer(:,:,:)
    real(fp) :: rms, av(size(buffer, 3))
    integer :: i, n
    integer(int64) :: nxny

    nxny = size(buffer, 1, kind = int64) * size(buffer, 2, kind = int64)
    n = size(buffer, 3)

    do concurrent (i = 1:n)
      av(i) = sum(buffer(:,:,i)) / nxny
    end do

    rms = 0
    do i = 1, n - 1
      rms = rms + sum((buffer(:,:,i) - av(i) - buffer(:,:,i+1) + av(i+1))**2) / (2 * nxny)
    end do

    rms = sqrt(rms / (n - 1))
  end function

end module stacking
