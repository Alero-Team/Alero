//! A long notification reply crosses the wire unchanged: no truncation, any Unicode.
use pb_core::frame::{read_frame_max, write_frame_max, MAX_APP_BODY};
use serde_json::json;

#[test]
fn ten_thousand_emoji_reply_round_trips_exactly() {
    let text = "👋🏽 ñ «» 中文 👨‍👩‍👧‍👦\n".repeat(1000) + &"x".repeat(10_000);
    let m = json!({"type": "pb.x.notif.reply", "body": {"key": "0|com.whatsapp|1", "text": text, "request": "1:2"}});
    let mut wire = Vec::new();
    write_frame_max(&mut wire, &m, MAX_APP_BODY).unwrap();
    let back = read_frame_max(&mut wire.as_slice(), MAX_APP_BODY).unwrap();
    assert_eq!(back["body"]["text"].as_str().unwrap(), text);
}

#[test]
fn a_reply_past_the_frame_is_refused_not_cut() {
    let m = json!({"type": "pb.x.notif.reply", "body": {"text": "x".repeat(MAX_APP_BODY + 1)}});
    assert!(write_frame_max(&mut Vec::new(), &m, MAX_APP_BODY).is_err());
}
