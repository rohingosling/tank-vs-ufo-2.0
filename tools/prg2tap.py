#!/usr/bin/env python3
#-----------------------------------------------------------------------------------------------------------------------
# Program: prg2tap
# Version: 1.0
# Author:  Rohin Gosling
#
# Description:
#
#   Encode a Commodore .prg as a KERNAL-format .tap v1 image. Generates a Commodore Datasette tape image that VICE
#   (or real hardware via the tape interface) can load via the standard KERNAL LOAD routine. Targets VIC-20 and C64;
#   the on-tape protocol is identical between them.
#
#   The PRG's first two bytes are the little-endian load address; the rest is the data payload. The generated .tap
#   contains a 192-byte HEADER block (with the PRG's load address baked in) followed by a DATA block holding the
#   payload, each block doubled with leader, sync, and end-of-block markers per the KERNAL tape protocol.
#
#   File type on tape is $01 (relocatable BASIC) so VICE's autostart ( -tape1 + autostart ) issues a plain LOAD / RUN
#   and the BASIC stub at the load address runs as expected. On an unexpanded VIC-20 BASIC starts at $1001, which
#   matches our PRG's load address; no relocation occurs.
#
#   References:
#
#   - VICE .tap v1 spec: <https://vice-emu.sourceforge.io/vice_17.html#SEC340>
#   - C64 wiki: "Tape image" + "Tape encoding" articles.
#
# Usage:
#
#   python prg2tap.py <input.prg> <output.tap> [filename-on-tape]
#-----------------------------------------------------------------------------------------------------------------------

from __future__ import annotations

import struct
import sys
from pathlib import Path

# Pulse lengths in .tap units (system cycles / 8). KERNAL SAVE-routine canonical values, valid for both C64 and VIC-20
# (same KERNAL tape code).

SHORT  = 0x30   # ~384 cycles
MEDIUM = 0x42   # ~528 cycles
LONG   = 0x56   # ~688 cycles

# Block timings.

HEADER_LEADER_PULSES = 0x6A00   # ~27 K short pulses ≈ generous pilot tone
DATA_LEADER_PULSES   = 0x1500   # ~5 K short pulses
GAP_PULSES           = 0x4F     # ~80 short pulses between block repeats
INTER_FILE_GAP       = 0x4F     # ~80 short pulses after a file


#-----------------------------------------------------------------------------------------------------------------------
# Function: encode_bit
#
# Description:
#
#   Encode one data bit as a pulse pair. A '0' bit is short+medium; a '1' bit is medium+short.
#
# Arguments:
#
#   bit : The bit to encode (0 or 1).
#
# Returns:
#
#   The two-pulse list encoding the bit.
#-----------------------------------------------------------------------------------------------------------------------

def encode_bit ( bit: int ) -> list [ int ]:

    # Encode one data bit as a pulse pair.

    return [ SHORT, MEDIUM ] if bit == 0 else [ MEDIUM, SHORT ]


#-----------------------------------------------------------------------------------------------------------------------
# Function: new_byte_marker
#
# Description:
#
#   Marker preceding each data byte: long + medium.
#
# Arguments:
#
#   None.
#
# Returns:
#
#   The two-pulse new-byte marker.
#-----------------------------------------------------------------------------------------------------------------------

def new_byte_marker () -> list [ int ]:

    # Return the marker preceding each data byte.

    return [ LONG, MEDIUM ]


#-----------------------------------------------------------------------------------------------------------------------
# Function: end_of_block_marker
#
# Description:
#
#   Marker after the last byte of a block: long + short.
#
# Arguments:
#
#   None.
#
# Returns:
#
#   The two-pulse end-of-block marker.
#-----------------------------------------------------------------------------------------------------------------------

def end_of_block_marker () -> list [ int ]:

    # Return the marker that follows the last byte of a block.

    return [ LONG, SHORT ]


#-----------------------------------------------------------------------------------------------------------------------
# Function: encode_byte
#
# Description:
#
#   Encode one byte: new-byte marker, 8 data bits LSB-first, odd parity.
#
# Arguments:
#
#   value : The byte value to encode.
#
# Returns:
#
#   The pulse list encoding the byte.
#-----------------------------------------------------------------------------------------------------------------------

def encode_byte ( value: int ) -> list [ int ]:

    # Encode one byte: new-byte marker, 8 data bits LSB-first, odd parity.

    pulses = new_byte_marker ()

    # Emit the 8 data bits LSB-first, accumulating odd parity as we go.

    parity = 1

    for i in range ( 8 ):

        bit = ( value >> i ) & 1
        pulses += encode_bit ( bit )
        parity ^= bit

    # Append the parity bit.

    pulses += encode_bit ( parity )

    # Return data to caller.

    return pulses


#-----------------------------------------------------------------------------------------------------------------------
# Function: leader
#
# Description:
#
#   Generate `count` short pulses (pilot tone / inter-block gap).
#
# Arguments:
#
#   count : Number of short pulses to generate.
#
# Returns:
#
#   The list of `count` short pulses.
#-----------------------------------------------------------------------------------------------------------------------

def leader ( count: int ) -> list [ int ]:

    # Generate the pilot tone / inter-block gap.

    return [ SHORT ] * count


#-----------------------------------------------------------------------------------------------------------------------
# Function: encode_block
#
# Description:
#
#   Encode one tape block:
#
#     sync ( sync_start .. sync_start - 8 ) + data + checksum + end-of-block
#
#   KERNAL READ-BLOCK starts a fresh XOR after the sync sequence, so the checksum covers ONLY the data bytes -- not
#   the sync countdown.
#
# Arguments:
#
#   data       : The block's data bytes.
#   sync_start : First byte of the 9-byte sync countdown ($89 for the first copy, $09 for the repeat).
#
# Returns:
#
#   The pulse list encoding the block.
#-----------------------------------------------------------------------------------------------------------------------

def encode_block ( data: bytes, sync_start: int ) -> list [ int ]:

    # Encode one tape block: sync countdown + data + checksum + end-of-block.

    sync = [ sync_start - i for i in range ( 9 ) ]

    # XOR checksum over the data bytes only (KERNAL READ-BLOCK starts a fresh XOR after the sync sequence).

    checksum = 0

    for b in data:
        checksum ^= b

    # Emit the sync countdown, the data, the checksum, and the end-of-block marker.

    pulses: list [ int ] = []

    for b in sync:
        pulses += encode_byte ( b )

    for b in data:
        pulses += encode_byte ( b )

    pulses += encode_byte ( checksum )
    pulses += end_of_block_marker ()

    # Return data to caller.

    return pulses


#-----------------------------------------------------------------------------------------------------------------------
# Function: encode_file
#
# Description:
#
#   Encode one tape file (header file or data file). Two copies of the same block are written; the loader
#   cross-checks them.
#
# Arguments:
#
#   data          : The file's block data bytes.
#   leader_pulses : Number of short pulses in the leading pilot tone.
#
# Returns:
#
#   The pulse list encoding the file.
#-----------------------------------------------------------------------------------------------------------------------

def encode_file ( data: bytes, leader_pulses: int ) -> list [ int ]:

    # Encode one tape file: pilot tone, then two copies of the block separated by a gap.

    pulses: list [ int ] = []
    pulses += leader ( leader_pulses )
    pulses += encode_block ( data, sync_start = 0x89 )
    pulses += leader ( GAP_PULSES )
    pulses += encode_block ( data, sync_start = 0x09 )
    pulses += leader ( INTER_FILE_GAP )

    # Return data to caller.

    return pulses


#-----------------------------------------------------------------------------------------------------------------------
# Function: make_header
#
# Description:
#
#   Build the 192-byte tape header block.
#
# Arguments:
#
#   file_type : Tape file type byte ($01 = relocatable BASIC).
#   start     : Load start address.
#   end       : Load end address.
#   filename  : Name on tape (upper-cased ASCII, padded or truncated to 16 characters).
#
# Returns:
#
#   The 192-byte header block.
#-----------------------------------------------------------------------------------------------------------------------

def make_header ( file_type: int, start: int, end: int, filename: str ) -> bytes:

    # Build the 192-byte tape header block.

    h       = bytearray ( 192 )
    h [ 0 ] = file_type
    h [ 1 ] = start & 0xFF
    h [ 2 ] = ( start >> 8 ) & 0xFF
    h [ 3 ] = end & 0xFF
    h [ 4 ] = ( end >> 8 ) & 0xFF

    # Bake the upper-cased file name into bytes 5..20, space-padded to 16 characters.

    name_bytes   = filename.upper ().encode ( 'ascii', errors = 'replace' )
    name_padded  = ( name_bytes + b' ' * 16 ) [ : 16 ]
    h [ 5 : 21 ] = name_padded

    # The remaining bytes are conventionally space-padded so a stock LIST would show them as blanks if dumped as
    # PETSCII.

    for i in range ( 21, 192 ):
        h [ i ] = 0x20

    # Return data to caller.

    return bytes ( h )


#-----------------------------------------------------------------------------------------------------------------------
# Function: encode_prg_to_tap_pulses
#
# Description:
#
#   Encode a complete .prg file as the pulse stream for a .tap body.
#
# Arguments:
#
#   prg_bytes : Raw .prg file contents (2-byte little-endian load address followed by the data payload).
#   filename  : Name to bake into the tape header.
#
# Returns:
#
#   The complete pulse stream for the .tap body.
#-----------------------------------------------------------------------------------------------------------------------

def encode_prg_to_tap_pulses ( prg_bytes: bytes, filename: str ) -> list [ int ]:

    # Encode a complete .prg file as the pulse stream for a .tap body.

    if len ( prg_bytes ) < 3:
        raise ValueError ( "PRG too small (need at least 2-byte load address + 1 byte data)" )

    # Split the PRG into its load address and data payload, and validate the address range.

    start = prg_bytes [ 0 ] | ( prg_bytes [ 1 ] << 8 )
    body  = prg_bytes [ 2 : ]
    end   = start + len ( body )

    if end > 0xFFFF:
        raise ValueError ( f"PRG extends past $FFFF (start ${start:04X}, length {len ( body )} bytes)" )

    # File type $01 = relocatable BASIC. On an unexpanded VIC-20 the BASIC start matches our load address ($1001),
    # so no relocation happens.

    header = make_header ( file_type = 0x01, start = start, end = end, filename = filename )

    # Emit the header file followed by the data file.

    pulses: list [ int ] = []
    pulses += encode_file ( header, leader_pulses = HEADER_LEADER_PULSES )
    pulses += encode_file ( body, leader_pulses = DATA_LEADER_PULSES )

    # Return data to caller.

    return pulses


#-----------------------------------------------------------------------------------------------------------------------
# Function: write_tap_v1
#
# Description:
#
#   Write a .tap v1 file.
#
#   Layout (per VICE spec):
#
#     [12]  "C64-TAPE-RAW"
#     [ 1]  version  = 1
#     [ 1]  platform = 0 (C64) / 1 (VIC-20) / 2 (C16/Plus4) -- v1 ignores; v2+ uses it. 0 is widely accepted.
#     [ 1]  video    = 0 (PAL) / 1 (NTSC)
#     [ 1]  reserved = 0
#     [ 4]  data length (little-endian uint32)
#     [..]  pulse data
#
# Arguments:
#
#   pulses    : The pulse stream for the tape body.
#   out_path  : Path where the .tap file will be written.
#   video_pal : True for PAL, False for NTSC (header video-standard byte).
#
# Returns:
#
#   None.
#-----------------------------------------------------------------------------------------------------------------------

def write_tap_v1 ( pulses: list [ int ], out_path: Path, video_pal: bool = True ) -> None:

    # Write the .tap v1 header and pulse data.

    with out_path.open ( 'wb' ) as f:

        f.write ( b'C64-TAPE-RAW' )
        f.write ( bytes ( [ 0x01 ] ) )                          # version 1
        f.write ( bytes ( [ 0x01 ] ) )                          # platform = VIC-20
        f.write ( bytes ( [ 0x00 if video_pal else 0x01 ] ) )   # video standard
        f.write ( bytes ( [ 0x00 ] ) )                          # reserved
        f.write ( struct.pack ( '<I', len ( pulses ) ) )
        f.write ( bytes ( pulses ) )


#-----------------------------------------------------------------------------------------------------------------------
# Function: main
#
# Description:
#
#   Command-line entry point: encode the input .prg as a .tap image and report the result.
#
# Arguments:
#
#   argv : Command-line argument list (sys.argv).
#
# Returns:
#
#   Process exit code: 0 on success, 1 when the input PRG is not found, 2 on a usage error.
#-----------------------------------------------------------------------------------------------------------------------

def main ( argv: list [ str ] ) -> int:

    # Validate the command line.

    if len ( argv ) < 3 or len ( argv ) > 4:
        
        print ( "Usage: prg2tap.py <input.prg> <output.tap> [filename-on-tape]" )
        return 2

    # Resolve the input, output, and on-tape file names.

    prg_path = Path ( argv [ 1 ] )
    tap_path = Path ( argv [ 2 ] )
    filename = argv [ 3 ] if len ( argv ) > 3 else prg_path.stem.upper ()

    if not prg_path.is_file ():

        print ( f"ERROR: input PRG not found: {prg_path}", file = sys.stderr )
        return 1

    # Encode the PRG and write the .tap image.

    prg_bytes = prg_path.read_bytes ()

    pulses = encode_prg_to_tap_pulses ( prg_bytes, filename = filename )
    write_tap_v1 ( pulses, tap_path )

    # Report what was written.

    start = prg_bytes [ 0 ] | ( prg_bytes [ 1 ] << 8 )
    end   = start + len ( prg_bytes ) - 2

    # Tape duration: sum of pulse values × 8 cycles, divided by clock.

    total_cycles  = sum ( pulses ) * 8
    duration_pal  = total_cycles / 1108405          # PAL VIC-20 clock
    duration_ntsc = total_cycles / 1022730          # NTSC VIC-20 clock

    print ( f"prg2tap: wrote {tap_path}" )
    print ( f"         source   : {prg_path} ({len ( prg_bytes )} bytes)" )
    print ( f"         load     : ${start:04X}-${end:04X} ({end - start} bytes data + 2-byte header)" )
    print ( f"         name     : '{filename.upper () [ :16 ]}'" )
    print ( f"         pulses   : {len ( pulses )}" )
    print ( f"         duration : ~{duration_pal:.1f} sec (PAL) / ~{duration_ntsc:.1f} sec (NTSC)" )

    # Return success to the shell.

    return 0

#-----------------------------------------------------------------------------------------------------------------------
# Program entry point.
#-----------------------------------------------------------------------------------------------------------------------

if __name__ == '__main__':

    sys.exit ( main ( sys.argv ) )
