use pb_core::frame::{decode, encode, MAX_BODY};
use serde_json::Value;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[test]
fn framing_vectors() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../protocol/vectors/framing.json");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(doc["maxBody"].as_u64().unwrap() as usize, MAX_BODY, "vectors and core disagree on MAX_BODY");
    let cases = doc["cases"].as_array().unwrap();
    assert!(!cases.is_empty());

    for c in cases {
        let id = c["id"].as_str().unwrap();
        let (op, input) = (c["op"].as_str().unwrap(), &c["input"]);
        let got: Result<Value, String> = match op {
            "encode" => encode(input).map(|b| serde_json::json!({ "hex": hex(&b) })).map_err(|e| e.code().into()),
            "decode" => decode(&unhex(input["hex"].as_str().unwrap()))
                .map(|(v, n)| serde_json::json!({ "ok": v, "consumed": n }))
                .map_err(|e| e.code().into()),
            _ => panic!("{id}: unknown op {op}"),
        };
        match c.get("expectedError") {
            Some(e) => assert_eq!(got.as_ref().err(), e.as_str().map(String::from).as_ref(), "{id}"),
            None => assert_eq!(got.as_ref().ok(), Some(&c["expected"]), "{id}"),
        }
    }
}
