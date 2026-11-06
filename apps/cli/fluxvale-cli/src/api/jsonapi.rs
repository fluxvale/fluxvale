//! The minimal JSON:API response envelope. Deliberately loose at this
//! layer — `data`/`attributes` stay `serde_json::Value`; the typed
//! structs live in [`crate::api::types`] (generated from the OpenAPI
//! artifact).

use serde_json::Value;

/// A JSON:API document: `{"data": …, "meta": …, "links": …}`.
#[derive(Debug, serde::Deserialize)]
pub struct Document {
    /// One resource object, an array of them, or absent.
    #[serde(default)]
    pub data: Option<Value>,
    #[serde(default)]
    pub meta: Option<Value>,
    #[serde(default)]
    pub links: Option<Value>,
}

/// The one piece of a resource object the CLI needs structurally:
/// `{"type", "id", "attributes": {…}}`.
#[derive(Debug, Clone, PartialEq)]
pub struct Resource {
    pub r#type: String,
    pub id: String,
    pub attributes: Value,
}

impl Document {
    /// The document's resources, whether `data` held one object or an
    /// array. Malformed resource objects are skipped, not fatal — the
    /// typed layer decides what's required.
    pub fn resources(&self) -> Vec<Resource> {
        let mut out = Vec::new();
        match &self.data {
            Some(Value::Array(items)) => {
                out.extend(items.iter().filter_map(parse_resource));
            }
            Some(Value::Object(_)) => {
                if let Some(resource) = self.data.as_ref().and_then(parse_resource) {
                    out.push(resource);
                }
            }
            _ => {}
        }
        out
    }
}

fn parse_resource(value: &Value) -> Option<Resource> {
    let object = value.as_object()?;
    let type_ = object.get("type")?.as_str()?.to_string();
    let id = object.get("id")?.as_str()?.to_string();
    let attributes = object.get("attributes").cloned().unwrap_or(Value::Null);
    Some(Resource {
        r#type: type_,
        id,
        attributes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_a_single_resource_document() {
        let raw = json!({
            "data": {
                "type": "user",
                "id": "01ABC",
                "attributes": {"email": "me@example.com", "platform_role": "user"},
                "relationships": {}
            }
        });
        let document: Document = serde_json::from_value(raw).unwrap();
        let resources = document.resources();
        assert_eq!(resources.len(), 1);
        assert_eq!(resources[0].r#type, "user");
        assert_eq!(resources[0].id, "01ABC");
        assert_eq!(resources[0].attributes["email"], "me@example.com");
    }

    #[test]
    fn parses_an_array_document() {
        let raw = json!({
            "data": [
                {"type": "instance", "id": "1", "attributes": {"name": "web"}},
                {"type": "instance", "id": "2", "attributes": {"name": "db"}}
            ]
        });
        let document: Document = serde_json::from_value(raw).unwrap();
        assert_eq!(document.resources().len(), 2);
    }

    #[test]
    fn absent_and_malformed_data_are_not_fatal() {
        let document: Document = serde_json::from_str("{}").unwrap();
        assert!(document.resources().is_empty());

        let raw = json!({"data": {"type": "instance"}});
        let document: Document = serde_json::from_value(raw).unwrap();
        assert!(document.resources().is_empty(), "missing id is skipped");
    }
}
