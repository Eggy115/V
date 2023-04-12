module mmap

import os

#include <windows.h>
#include <errno.h>
#include <io.h>
#include <sys/types.h>

// ----------------------------------------------------------------------------
// Constants: please make sure, the same constants exist in *_nix.c.v
// ----------------------------------------------------------------------------

// TODO I would prefer the different constants to be an enum. Should be more type-safe.
pub const (
	prot_none  = 0
	prot_read  = 1
	prot_write = 2
	prot_exec  = 4
)

pub const (
	map_file      = 0
	map_shared    = 1
	map_private   = 2
	map_type      = 0xf
	map_fixed     = 0x10
	map_anonymous = 0x20
	map_anon      = map_anonymous
)

// Flags for msync.
pub const (
	ms_async      = 1
	ms_sync       = 2
	ms_invalidate = 4
)

// ----------------------------------------------------------------------------
// Define the Windows functions
// ----------------------------------------------------------------------------

/*
HANDLE CreateFileMappingA(
  HANDLE                hFile,
  LPSECURITY_ATTRIBUTES lpFileMappingAttributes,
  DWORD                 flProtect,
  DWORD                 dwMaximumSizeHigh,
  DWORD                 dwMaximumSizeLow,
  LPCSTR                lpName
);
*/
fn C.CreateFileMapping(hFile os.HANDLE, lpFileMappingAttributes voidptr, flProtect int, dwMaxSizeHigh int, dwMaxSizeLow int, lpName &char) os.HANDLE

/*
LPVOID MapViewOfFile(
  HANDLE hFileMappingObject,
  DWORD  dwDesiredAccess,
  DWORD  dwFileOffsetHigh,
  DWORD  dwFileOffsetLow,
  SIZE_T dwNumberOfBytesToMap
);
*/
fn C.MapViewOfFile(hFileMappingObject os.HANDLE, dwDesiredAccess int, dwFileOffsetHigh int, dwFileOffsetLow int, dwNumberOfBytesToMap size_t) voidptr

fn C.UnmapViewOfFile(addr voidptr) int
fn C.VirtualLock(addr voidptr, len size_t) int
fn C.VirtualUnlock(addr voidptr, len size_t) int
fn C.FlushViewOfFile(addr voidptr, len size_t) int

/*
BOOL VirtualProtect(
  LPVOID lpAddress,
  SIZE_T dwSize,
  DWORD  flNewProtect,
  PDWORD lpflOldProtect
);
*/
fn C.VirtualProtect(lpAddress voidptr, dwSize size_t, flNewProtect int, lpflOldProtect &int) int

fn C.GetLastError() int

/*
intptr_t _get_osfhandle(
   int fd
);
*/
fn C._get_osfhandle(fd int) os.HANDLE

/*
HLOCAL LocalFree(
  _Frees_ptr_opt_ HLOCAL hMem
);
*/
fn C.LocalFree(hMEM voidptr) voidptr

/*
DWORD FormatMessageA(
  DWORD   dwFlags,
  LPCVOID lpSource,
  DWORD   dwMessageId,
  DWORD   dwLanguageId,
  LPSTR   lpBuffer,
  DWORD   nSize,
  va_list *Arguments
);
*/
fn C.FormatMessageA(dwFlags int, lpSource voidptr, dwMessageId int, dwLanguageId int, lpBuffer voidptr, nSize int, arguments voidptr) int

// ----------------------------------------------------------------------------
// (Windows) Implementations
// ----------------------------------------------------------------------------

// get_last_error_as_string  Retrieve the (windows) last-error-ID and
// determine the associated error message
fn get_last_error_as_string() string {
	// Get the error message ID, if any.
	error_message_id := C.GetLastError()
	if error_message_id == 0 {
		return '(0) no error'
	}
	// eprintln("Error id: $error_message_id")

	mut message_buffer := &char(C.NULL)

	// Ask Win32 to give us the string version of that message ID.
	// The parameters we pass in, tells Win32 to create the buffer
	// that holds the message for us (because we don't yet know how
	// long the message string will be).
	size := C.FormatMessageA(C.FORMAT_MESSAGE_ALLOCATE_BUFFER | C.FORMAT_MESSAGE_FROM_SYSTEM | C.FORMAT_MESSAGE_IGNORE_INSERTS,
		C.NULL, error_message_id, C.MAKELANGID(C.LANG_NEUTRAL, C.SUBLANG_DEFAULT), &message_buffer,
		0, C.NULL)

	// Copy the error message
	message := unsafe { message_buffer.vstring_with_len(size) }
	// eprintln("Error msg: $message")

	// Free the Win32's string's buffer.
	C.LocalFree(message_buffer)

	return '($error_message_id) $message'
}

// map_mmap_prot_page  Determine the windows code needed to set 'protection'
// of the memory mapped region.
fn map_mmap_prot_page(prot int) int {
	mut protect := int(0)

	if prot != mmap.prot_none {
		if (prot & mmap.prot_exec) != 0 {
			protect = if (prot & mmap.prot_write) != 0 {
				C.PAGE_EXECUTE_READWRITE
			} else {
				C.PAGE_EXECUTE_READ
			}
		} else {
			protect = if (prot & mmap.prot_write) != 0 { C.PAGE_READWRITE } else { C.PAGE_READONLY }
		}
	}

	return protect
}

// map_mmap_prot_file
fn map_mmap_prot_file(prot int) int {
	mut desired_access := int(0)

	if prot == mmap.prot_none {
		return desired_access
	}

	if (prot & mmap.prot_read) != 0 {
		desired_access |= C.FILE_MAP_READ
	}

	if (prot & mmap.prot_write) != 0 {
		desired_access |= C.FILE_MAP_WRITE
	}

	if (prot & mmap.prot_exec) != 0 {
		desired_access |= C.FILE_MAP_EXECUTE
	}

	return desired_access
}

// ----------------------------------------------------------------------------
// (Windows) Memory mapping API
// ----------------------------------------------------------------------------

// mmap Create first a (windows) file mapping and then map a view on the content.
pub fn mmap(args MmapOptions) ?voidptr {
	if args.len <= 0 {
		return error("Parameter 'len' must be > 0")
	}

	if (args.flags & mmap.map_fixed) != 0 {
		return error('Unsupported flag combination')
	}

	if args.prot == mmap.prot_exec {
		return error('Usupported protection combinations')
	}

	dw_file_offset_low := int(args.offset & 0xFFFFFFFF)
	dw_file_offset_high := int((args.offset >> 32) & 0xFFFFFFFF)

	protect := map_mmap_prot_page(args.prot)
	desired_access := map_mmap_prot_file(args.prot)

	max_size := args.offset + args.len
	dw_max_size_low := int(max_size & 0xFFFFFFFF)
	dw_max_size_high := int((max_size >> 32) & 0xFFFFFFFF)

	h := if (args.flags & mmap.map_anonymous) == 0 {
		C._get_osfhandle(args.fd)
	} else {
		C.INVALID_HANDLE_VALUE
	}

	if ((args.flags & mmap.map_anonymous) == 0) && (h == C.INVALID_HANDLE_VALUE) {
		return error('Bad file descriptor')
	}

	fm := C.CreateFileMapping(h, C.NULL, protect, dw_max_size_high, dw_max_size_low, C.NULL)
	if fm == C.NULL {
		msg := get_last_error_as_string()
		return error('CreateFileMapping() failed: $msg')
	} else {
		defer {
			C.CloseHandle(fm)
		}
	}

	map := C.MapViewOfFile(fm, desired_access, dw_file_offset_high, dw_file_offset_low,
		args.len)
	if map == C.NULL {
		msg := get_last_error_as_string()
		return error('MapViewOfFile() failed: $msg')
	}

	return map
}

// munmap Unmap the memory mapping
pub fn munmap(addr voidptr, len u64) ? {
	if C.UnmapViewOfFile(addr) == 0 {
		msg := get_last_error_as_string()
		return error('munmap() failed: $msg')
	}
}

// mprotect
pub fn mprotect(addr voidptr, len u64, prot int) ? {
	new_protect := map_mmap_prot_page(prot)
	old_protect := 0

	if C.VirtualProtect(addr, len, new_protect, &old_protect) == 0 {
		msg := get_last_error_as_string()
		return error('mprotect() failed: $msg')
	}
}

// msync
pub fn msync(addr voidptr, len u64, flags int) ? {
	if C.FlushViewOfFile(addr, len) == 0 {
		msg := get_last_error_as_string()
		return error('msync() failed: $msg')
	}
}

// mlock
pub fn mlock(addr voidptr, len u64) ? {
	if C.VirtualLock(addr, len) == 0 {
		msg := get_last_error_as_string()
		return error('mlock() failed: $msg')
	}
}

// munlock
pub fn munlock(addr voidptr, len u64) ? {
	if C.VirtualUnlock(addr, len) == 0 {
		msg := get_last_error_as_string()
		return error('munlock() failed: $msg')
	}
}
