use std::{
    io,
    process::{Child, Command},
    thread,
    time::{Duration, Instant},
};

pub struct OwnedChild {
    child: Child,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}

impl OwnedChild {
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        #[allow(unused_mut)]
        let mut child = command.spawn()?;
        #[cfg(windows)]
        let job = match super::process_windows::assign_kill_on_close_job(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = wait_until_exit(&mut child, Duration::from_secs(1));
                return Err(error);
            }
        };
        Ok(Self {
            child,
            #[cfg(windows)]
            _job: job,
        })
    }

    pub fn is_running(&mut self) -> io::Result<bool> {
        self.child.try_wait().map(|status| status.is_none())
    }

    #[cfg(windows)]
    pub fn owns_tcp_listener(&mut self, port: u16) -> io::Result<bool> {
        if !self.is_running()? {
            return Ok(false);
        }
        super::process_windows::tcp_listener_owner_pid(port)
            .map(|owner| owner == Some(self.child.id()))
    }

    pub fn stop_with_timeout(&mut self, timeout: Duration) -> io::Result<()> {
        if !self.is_running()? {
            return Ok(());
        }
        if let Err(error) = terminate(&mut self.child) {
            if self.is_running()? {
                return Err(error);
            }
            return Ok(());
        }
        if wait_until_exit(&mut self.child, timeout)? {
            return Ok(());
        }
        self.child.kill()?;
        if wait_until_exit(&mut self.child, Duration::from_secs(1))? {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "owned child did not exit after force stop",
            ))
        }
    }
}

fn wait_until_exit(child: &mut Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(unix)]
fn terminate(child: &mut Child) -> io::Result<()> {
    extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }

    // SAFETY: `child.id()` is the live process owned by BirdNion; signal 15 is SIGTERM.
    if unsafe { kill(child.id() as i32, 15) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
fn terminate(child: &mut Child) -> io::Result<()> {
    child.kill()
}
