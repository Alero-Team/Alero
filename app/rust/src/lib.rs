pub mod api;
mod frb_generated;
#[cfg(target_os = "android")]
mod jni_api;

/// App messages the Kotlin service answers itself (Features.kt routes them). A kind missing here never reaches
/// Android: add every new phone-side message to this list.
#[allow(dead_code)] // used by the Android-only JNI module
pub(crate) fn service_kind(kind: &str) -> bool {
    ["pb.x.fs.", "pb.x.sms.", "pb.x.phone."].iter().any(|p| kind.starts_with(p))
        || matches!(
            kind,
            "pb.x.info.request"
                | "pb.x.clip"
                | "pb.x.media.cmd"
                | "pb.x.media.request"
                | "pb.x.notif.dismiss"
                | "pb.x.notif.reply"
                | "pb.x.notif.action"
                | "pb.x.call.cmd"
                | "pb.x.call.dial"
        )
}


#[cfg(test)]
mod tests {
    #[test]
    fn the_service_gets_every_phone_feature() {
        for k in ["pb.x.fs.list", "pb.x.sms.threads.request", "pb.x.sms.send", "pb.x.call.cmd", "pb.x.call.dial", "pb.x.notif.action", "pb.x.phone.find"] {
            assert!(super::service_kind(k), "{k}");
        }
        for k in ["pb.x.screen.frame", "pb.x.call", "pb.x.info"] {
            assert!(!super::service_kind(k), "{k}");
        }
    }
}
