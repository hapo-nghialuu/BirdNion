use std::{
    fs::File,
    io,
    mem::size_of,
    os::windows::{ffi::OsStrExt, io::FromRawHandle},
    path::Path,
    ptr,
};
use windows_sys::Win32::{
    Foundation::{LocalFree, GENERIC_WRITE, INVALID_HANDLE_VALUE},
    Security::{
        Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1},
        SetFileSecurityW, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
        SECURITY_ATTRIBUTES,
    },
    Storage::FileSystem::{CreateFileW, CREATE_NEW, FILE_ATTRIBUTE_NORMAL},
};

pub(super) fn open_private_temp(path: &Path) -> io::Result<File> {
    let wide = wide_path(path)?;
    let descriptor_text: Vec<u16> = "D:P(A;;FA;;;OW)(A;;FA;;;SY)"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut descriptor = ptr::null_mut();
    // SAFETY: input is NUL-terminated; Windows allocates `descriptor` on success.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor_text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    // SAFETY: path and descriptor remain valid for the duration of CreateFileW.
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_WRITE,
            0,
            &attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL,
            ptr::null_mut(),
        )
    };
    let create_error = if handle == INVALID_HANDLE_VALUE {
        Some(io::Error::last_os_error())
    } else {
        None
    };
    // SAFETY: the conversion API allocated this buffer with LocalAlloc.
    unsafe { LocalFree(descriptor) };
    if let Some(error) = create_error {
        return Err(error);
    }
    // SAFETY: `handle` is unique and ownership transfers to `File`.
    Ok(unsafe { File::from_raw_handle(handle) })
}

pub(super) fn set_private_directory_acl(path: &Path) -> io::Result<()> {
    let wide = wide_path(path)?;
    let descriptor_text: Vec<u16> = "D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut descriptor = ptr::null_mut();
    // SAFETY: input is NUL-terminated; Windows allocates `descriptor` on success.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor_text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: path and descriptor remain valid for the duration of the call.
    let applied = unsafe {
        SetFileSecurityW(
            wide.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
    };
    let apply_error = if applied == 0 {
        Some(io::Error::last_os_error())
    } else {
        None
    };
    // SAFETY: the conversion API allocated this buffer with LocalAlloc.
    unsafe { LocalFree(descriptor) };
    match apply_error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

pub(super) fn wide_path(path: &Path) -> io::Result<Vec<u16>> {
    let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
    if value.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Windows path contains NUL",
        ));
    }
    value.push(0);
    Ok(value)
}
