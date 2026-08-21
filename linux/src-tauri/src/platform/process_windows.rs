use std::{
    io,
    mem::size_of,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    process::Child,
    ptr,
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_INSUFFICIENT_BUFFER, NO_ERROR},
    NetworkManagement::IpHelper::{
        GetExtendedTcpTable, MIB_TCPROW_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER,
    },
    Networking::WinSock::AF_INET,
    System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    },
};

pub(super) fn assign_kill_on_close_job(child: &Child) -> io::Result<OwnedHandle> {
    // SAFETY: null security/name pointers request an unnamed job with default security.
    let job = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
    if job.is_null() {
        return Err(io::Error::last_os_error());
    }
    let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: `info` has the exact structure and size requested by this class.
    let configured = unsafe {
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    };
    // SAFETY: the child process handle stays valid while `child` is alive.
    let assigned =
        configured != 0 && unsafe { AssignProcessToJobObject(job, child.as_raw_handle()) } != 0;
    if assigned {
        // SAFETY: `job` is unique and ownership transfers to `OwnedHandle`.
        Ok(unsafe { OwnedHandle::from_raw_handle(job) })
    } else {
        let error = io::Error::last_os_error();
        // SAFETY: `job` was created successfully and remains owned here.
        unsafe { CloseHandle(job) };
        Err(error)
    }
}

pub(super) fn tcp_listener_owner_pid(port: u16) -> io::Result<Option<u32>> {
    let mut size = 0u32;
    // SAFETY: null buffer asks Windows for the required allocation size.
    let first = unsafe {
        GetExtendedTcpTable(
            ptr::null_mut(),
            &mut size,
            0,
            AF_INET as u32,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    if first != ERROR_INSUFFICIENT_BUFFER || size < size_of::<u32>() as u32 {
        return Err(io::Error::from_raw_os_error(first as i32));
    }
    let mut buffer = Vec::new();
    let mut complete = false;
    for _ in 0..3 {
        buffer.resize(size as usize, 0);
        // SAFETY: buffer is writable for `size` bytes requested by Windows.
        let result = unsafe {
            GetExtendedTcpTable(
                buffer.as_mut_ptr().cast(),
                &mut size,
                0,
                AF_INET as u32,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            )
        };
        if result == NO_ERROR {
            complete = true;
            break;
        }
        if result != ERROR_INSUFFICIENT_BUFFER {
            return Err(io::Error::from_raw_os_error(result as i32));
        }
    }
    if !complete {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "TCP listener table kept growing",
        ));
    }
    let count = u32::from_ne_bytes(buffer[..4].try_into().unwrap_or_default()) as usize;
    let row_size = size_of::<MIB_TCPROW_OWNER_PID>();
    for index in 0..count {
        let offset = size_of::<u32>() + index * row_size;
        if offset + row_size > buffer.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid TCP table",
            ));
        }
        // SAFETY: bounds were checked; rows may be unaligned in the byte buffer.
        let row = unsafe {
            ptr::read_unaligned(buffer.as_ptr().add(offset).cast::<MIB_TCPROW_OWNER_PID>())
        };
        if u16::from_be(row.dwLocalPort as u16) == port {
            return Ok(Some(row.dwOwningPid));
        }
    }
    Ok(None)
}
