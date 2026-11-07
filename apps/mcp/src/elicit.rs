//! The destructive verbs' confirmation gate (`instances_destroy`,
//! `backups_restore`) — MCP elicitation over the stateless rev.
//!
//! The mechanism is SEP-2322 (rmcp's `servers_mrtr` example, the
//! pattern the SDK builds for stateless streamable HTTP): a
//! server-initiated `elicitation/create` request CANNOT round-trip on
//! this transport — `NeverSessionManager` + per-request routing
//! reject the client's JSON-RPC response POST ("stateless server does
//! not accept JSON-RPC responses"), and the 2026-07-28 rev forbids
//! server-to-client requests outright. So the tools/call itself
//! returns an [`InputRequiredResult`] carrying the confirm question
//! plus a sealed [`Pending`] target in `requestState`; the client
//! fulfills the question, then retries the call with
//! `inputResponses` and the echoed `requestState`.
//!
//! The seal is the "handler's own state": HMAC-signed
//! (sha256-of-the-calling-PAT as the key, so a seal never opens under
//! another token) and TTL-bounded. On the retry the verb runs the
//! SEALED target — a re-sent confirm cannot steer a different id,
//! because the re-sent arguments are not consulted.
//!
//! A client that cannot confirm at all (pre-2026-07-28 revs, or no
//! elicitation capability declared) gets an honest tool error naming
//! the panel — never a silent no-op, never a protocol crash, and the
//! verb never runs.

use std::time::Duration;

use rmcp::{
    RoleServer,
    model::{
        ElicitRequest, ElicitRequestParams, ElicitResult, ElicitationAction, ElicitationSchema,
        InputRequest, InputRequests, InputRequiredResult, InputResponses, ProtocolVersion,
        RequestStateCodec, SealOptions,
    },
    service::RequestContext,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};

use fluxvale_api::Token;

/// The input-request key the confirm question rides under.
pub(crate) const CONFIRM_KEY: &str = "confirm";

/// How long a sealed confirmation stays open — a stale "yes" must not
/// resurrect a destroy hours later.
pub(crate) const CONFIRM_TTL: Duration = Duration::from_secs(10 * 60);

/// The non-yes arms' one answer (the Elixir server's copy).
pub(crate) const CANCELLED: &str = "cancelled. Nothing was changed.";

/// A seal that failed to open — integrity, expiry, another token's
/// key, or a payload that isn't ours. One line for all of them (the
/// codec's own guidance: map opening failures to a single
/// client-facing error).
pub(crate) const INVALID_SEAL: &str = "this confirmation is invalid, expired, or from another token — call the tool again to start over";

/// A seal minted by the OTHER destructive tool.
pub(crate) const WRONG_TOOL: &str =
    "this confirmation belongs to another action — call the tool again to start over";

/// The no-capability arm's honest error (the brief's copy, the tool's
/// own name in it).
pub(crate) fn honest_error(tool: &str) -> String {
    format!(
        "this client cannot confirm destructive actions: {tool} needs a client that \
         supports elicitation (the 2026-07-28 stateless protocol revision declaring the \
         elicitation capability), or the panel. Nothing was changed"
    )
}

/// Can this request's client confirm a destructive action? The
/// stateless rev's two declarations: the negotiated protocol version
/// (an [`InputRequiredResult`] only reaches 2026-07-28+ peers — the
/// SDK turns it into a protocol error for older ones) and the
/// per-request client capabilities (the stateless rev carries them on
/// EVERY request's _meta, which is what rmcp's
/// `client_capabilities()` reads).
pub(crate) fn confirm_capable(context: &RequestContext<RoleServer>) -> bool {
    context
        .protocol_version()
        .is_some_and(|version| version >= ProtocolVersion::V_2026_07_28)
        && context
            .client_capabilities()
            .is_some_and(|capabilities| capabilities.elicitation.is_some())
}

/// The confirm question: the Elixir server's one schema — a required
/// yes/no enum — under the `confirm` key.
fn confirm_question(message: String) -> InputRequests {
    // The schema is built from JSON (rmcp's own mrtr example's
    // pattern) — the builder API is chummier than the shape.
    let schema: ElicitationSchema = serde_json::from_value(json!({
        "type": "object",
        "properties": {
            "confirm": {
                "type": "string",
                "enum": ["yes", "no"],
                "title": "Confirm",
                "description": "Yes runs it. No cancels without changing anything"
            }
        },
        "required": ["confirm"]
    }))
    .expect("the confirm schema is a valid elicitation schema");
    let mut requests = InputRequests::new();
    requests.insert(
        CONFIRM_KEY.to_string(),
        InputRequest::Elicitation(ElicitRequest::new(
            ElicitRequestParams::FormElicitationParams {
                meta: None,
                message,
                requested_schema: schema,
            },
        )),
    );
    requests
}

/// The first round's whole answer: the question plus the sealed
/// target. At least one of inputRequests/requestState must ride —
/// this result carries both.
pub(crate) fn input_required(message: String, sealed: String) -> InputRequiredResult {
    InputRequiredResult::new(Some(confirm_question(message)), Some(sealed))
}

/// The confirmed target, sealed between the rounds. The tag is the
/// tool's own name — a seal never opens for the other tool's handler
/// (see [`WRONG_TOOL`]).
#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "tool")]
pub(crate) enum Pending {
    #[serde(rename = "instances_destroy")]
    DestroyInstance { instance_id: String },
    #[serde(rename = "backups_restore")]
    RestoreBackup {
        instance_id: String,
        backup_run_id: String,
    },
}

/// The seal's HMAC key: sha256 of the calling PAT — exactly
/// `RequestStateCodec::MIN_KEY_LENGTH` bytes, and a per-token binding
/// for free: the client already holds its own PAT (so it can no more
/// forge a seal than answer the question itself — the gate is a
/// guard against agent mistakes, the platform's scopes remain the
/// enforcement), while a DIFFERENT token can never open the seal.
fn codec(token: &Token) -> RequestStateCodec {
    let key = Sha256::digest(token.expose().as_bytes());
    RequestStateCodec::try_new(key.to_vec())
        .expect("sha256 output satisfies the minimum key length")
}

/// Seal the confirmed-target state for the retry round.
pub(crate) fn seal<T: Serialize>(token: &Token, pending: &T) -> Result<String, String> {
    codec(token)
        .seal_json_with(pending, &SealOptions::new().ttl(CONFIRM_TTL))
        .map_err(|_| "the confirmation could not be sealed — call the tool again".to_string())
}

/// Open the echoed state. Any failure is [`INVALID_SEAL`].
pub(crate) fn open(token: &Token, sealed: &str) -> Result<Pending, String> {
    codec(token)
        .open_json(sealed)
        .map_err(|_| INVALID_SEAL.to_string())
}

/// The confirm round's verdict. Only an explicit "yes" runs the verb
/// — decline, cancel, a missing response, or any other content
/// cancels (the Elixir handler's own rule: everything but
/// `"yes"` is the no-arm).
pub(crate) enum ConfirmAnswer {
    Yes,
    Cancelled,
}

pub(crate) fn confirm_answer(responses: &Option<InputResponses>) -> ConfirmAnswer {
    let yes = responses
        .as_ref()
        .and_then(|responses| responses.get(CONFIRM_KEY))
        .and_then(|value| ElicitResult::deserialize(value).ok())
        .is_some_and(|result| {
            result.action == ElicitationAction::Accept
                && result
                    .content
                    .as_ref()
                    .and_then(|content| content.get("confirm"))
                    == Some(&json!("yes"))
        });
    if yes {
        ConfirmAnswer::Yes
    } else {
        ConfirmAnswer::Cancelled
    }
}

/// The `backups_restore` id fence (the Elixir tool schema's own uuid
/// pattern): a garbage run id gets its refusal BEFORE the question —
/// a confirm round trip for an unrestorable id is wasted work for
/// the human.
pub(crate) fn valid_run_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_confirm_question_is_the_yes_no_enum() {
        let result = input_required("destroy it?".into(), "sealed".into());
        let request = result
            .input_requests
            .expect("the question rides")
            .get(CONFIRM_KEY)
            .cloned()
            .expect("the confirm key");
        let InputRequest::Elicitation(elicit) = request else {
            panic!("the input request is an elicitation");
        };
        let ElicitRequestParams::FormElicitationParams {
            message,
            requested_schema,
            ..
        } = elicit.params
        else {
            panic!("the elicitation is a form question");
        };
        assert_eq!(message, "destroy it?");
        let schema = serde_json::to_value(requested_schema).expect("serializes");
        assert_eq!(
            schema["properties"]["confirm"]["enum"],
            json!(["yes", "no"])
        );
        assert_eq!(schema["required"], json!(["confirm"]));
        // The state rides alongside (at least one of the two must).
        assert_eq!(result.request_state.as_deref(), Some("sealed"));
    }

    #[test]
    fn a_seal_round_trips_only_under_its_own_token() {
        let token = Token::new("fvpat_caller_one");
        let pending = Pending::DestroyInstance {
            instance_id: "i1".into(),
        };
        let sealed = seal(&token, &pending).unwrap();
        assert_eq!(open(&token, &sealed).unwrap(), pending);

        // Another token's key never opens it.
        let other = Token::new("fvpat_caller_two");
        assert_eq!(open(&other, &sealed).unwrap_err(), INVALID_SEAL);

        // Tampering fails the integrity check.
        let mut tampered = sealed.clone();
        tampered.replace_range(0..1, if sealed.starts_with('A') { "B" } else { "A" });
        assert_eq!(open(&token, &tampered).unwrap_err(), INVALID_SEAL);

        // A valid seal of a payload that isn't a Pending is the same
        // single client-facing line.
        let garbage = seal(&token, &json!({"nope": true})).unwrap();
        assert_eq!(open(&token, &garbage).unwrap_err(), INVALID_SEAL);
    }

    #[test]
    fn the_pending_tag_is_the_tool_name() {
        let token = Token::new("fvpat_t");
        let pending = Pending::RestoreBackup {
            instance_id: "i1".into(),
            backup_run_id: "11111111-2222-3333-4444-555555555555".into(),
        };
        let sealed = seal(&token, &pending).unwrap();
        assert_eq!(open(&token, &sealed).unwrap(), pending);
    }

    #[test]
    fn only_an_explicit_yes_confirms() {
        use serde_json::Value;

        let elicit = |action: ElicitationAction, content: Option<Value>| {
            let mut responses = InputResponses::new();
            responses.insert(
                CONFIRM_KEY.to_string(),
                serde_json::to_value(
                    ElicitResult::new(action).with_content(content.unwrap_or_else(|| json!({}))),
                )
                .unwrap(),
            );
            Some(responses)
        };

        let yes = elicit(ElicitationAction::Accept, Some(json!({"confirm": "yes"})));
        assert!(matches!(confirm_answer(&yes), ConfirmAnswer::Yes));

        for answer in [
            elicit(ElicitationAction::Accept, Some(json!({"confirm": "no"}))),
            elicit(ElicitationAction::Accept, Some(json!({}))),
            elicit(ElicitationAction::Decline, Some(json!({"confirm": "yes"}))),
            elicit(ElicitationAction::Cancel, None),
            None,
            Some(InputResponses::new()),
        ] {
            assert!(
                matches!(confirm_answer(&answer), ConfirmAnswer::Cancelled),
                "answer {answer:?} must cancel"
            );
        }

        // Garbage under the confirm key cancels too — never a crash.
        let mut garbage = InputResponses::new();
        garbage.insert(CONFIRM_KEY.to_string(), json!("not an elicit result"));
        assert!(matches!(
            confirm_answer(&Some(garbage)),
            ConfirmAnswer::Cancelled
        ));
    }

    #[test]
    fn the_honest_error_names_the_tool_and_the_panel() {
        let message = honest_error("instances_destroy");
        assert!(
            message.contains("cannot confirm destructive actions"),
            "message: {message}"
        );
        assert!(message.contains("instances_destroy"));
        assert!(message.contains("elicitation"));
        assert!(message.contains("panel"));
        assert!(message.contains("Nothing was changed"));
    }

    #[test]
    fn a_seal_that_cannot_serialize_answers_the_retry_line() {
        struct Unserializable;
        impl Serialize for Unserializable {
            fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
                Err(serde::ser::Error::custom("nope"))
            }
        }
        let err = seal(&Token::new("fvpat_t"), &Unserializable).unwrap_err();
        assert!(err.contains("could not be sealed"), "err: {err}");
    }

    #[test]
    fn run_ids_must_be_lowercase_uuids() {
        assert!(valid_run_id("11111111-2222-3333-4444-555555555555"));
        for bad in [
            "",
            "r9",
            "11111111-2222-3333-4444-55555555555", // too short
            "11111111-2222-3333-4444-5555555555555", // too long
            "1111111G-2222-3333-4444-555555555555", // not hex
            "11111111_2222-3333-4444-555555555555", // wrong separator
            "11111111-2222-3333-4444-55555555555G", // hex but not lowercase
        ] {
            assert!(!valid_run_id(bad), "{bad:?} must refuse");
        }
    }
}
