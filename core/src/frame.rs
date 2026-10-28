//! Control-message framing: u32 big-endian length + compact UTF-8 JSON body.
//! Spec: docs/architecture/Protocol.md §6. Vectors: protocol/vectors/framing.json.

use std::io::{Read, Write};

use serde_json::Value;

/// Max control body size (Protocol.md §6, proposal; revisit after spike S1).
pub const MAX_BODY: usize = 64 * 1024;

/// Max body of an application message (pb.x.*, Protocol.md §6.1): remote-screen frames and thumbnails.
/// Only paired devices reach that connection kind, so the larger buffer is not exposed to strangers.
pub const MAX_APP_BODY: usize = 256 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    Incomplete,
    PacketTooLarge,
    InvalidUtf8,
    InvalidJson,
    MissingType,
    Io,
}

impl FrameError {
    /// Stable symbolic code shared with the test vectors.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Io => "IO",
            Self::Incomplete => "INCOMPLETE",
            Self::PacketTooLarge => "PACKET_TOO_LARGE",
            Self::InvalidUtf8 => "INVALID_UTF8",
            Self::InvalidJson => "INVALID_JSON",
            Self::MissingType => "MISSING_TYPE",
        }
    }
}

fn check_type(v: &Value) -> Result<(), FrameError> {
    match v.get("type") {
        Some(Value::String(_)) => Ok(()),
        _ => Err(FrameError::MissingType),
    }
}

/// Serialize a message. Keys come out sorted and compact, so bytes are deterministic.
pub fn encode(msg: &Value) -> Result<Vec<u8>, FrameError> {
    encode_max(msg, MAX_BODY)
}

pub fn encode_max(msg: &Value, max: usize) -> Result<Vec<u8>, FrameError> {
    check_type(msg)?;
    let body = serde_json::to_vec(msg).map_err(|_| FrameError::InvalidJson)?;
    if body.len() > max {
        return Err(FrameError::PacketTooLarge);
    }
    let mut out = (body.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn write_frame<W: Write>(w: &mut W, msg: &Value) -> Result<(), FrameError> {
    w.write_all(&encode(msg)?).map_err(|_| FrameError::Io)
}

pub fn write_frame_max<W: Write>(w: &mut W, msg: &Value, max: usize) -> Result<(), FrameError> {
    w.write_all(&encode_max(msg, max)?).map_err(|_| FrameError::Io)
}

/// Read exactly one frame from a stream; the size check runs before the body is read.
pub fn read_frame<R: Read>(r: &mut R) -> Result<Value, FrameError> {
    read_frame_max(r, MAX_BODY)
}

pub fn read_frame_max<R: Read>(r: &mut R, max: usize) -> Result<Value, FrameError> {
    let mut buf = vec![0u8; 4];
    r.read_exact(&mut buf).map_err(|_| FrameError::Io)?;
    let len = u32::from_be_bytes(buf[..4].try_into().unwrap()) as usize;
    if len > max {
        return Err(FrameError::PacketTooLarge);
    }
    buf.resize(4 + len, 0);
    r.read_exact(&mut buf[4..]).map_err(|_| FrameError::Io)?;
    decode_max(&buf, max).map(|(v, _)| v)
}

/// Parse one frame from the front of `buf`; returns the message and bytes consumed.
/// The size check runs on the header alone so an oversize frame is never buffered.
pub fn decode(buf: &[u8]) -> Result<(Value, usize), FrameError> {
    decode_max(buf, MAX_BODY)
}

pub fn decode_max(buf: &[u8], max: usize) -> Result<(Value, usize), FrameError> {
    let header: [u8; 4] = buf.get(..4).ok_or(FrameError::Incomplete)?.try_into().unwrap();
    let len = u32::from_be_bytes(header) as usize;
    if len > max {
        return Err(FrameError::PacketTooLarge);
    }
    let body = buf.get(4..4 + len).ok_or(FrameError::Incomplete)?;
    let text = std::str::from_utf8(body).map_err(|_| FrameError::InvalidUtf8)?;
    let v: Value = serde_json::from_str(text).map_err(|_| FrameError::InvalidJson)?;
    check_type(&v)?;
    Ok((v, 4 + len))
}
