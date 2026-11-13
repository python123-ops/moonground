///|
// JSON parsing has already checked the token grammar. A rounded-to-zero
// nonzero mantissa must not be accepted as an exact integer zero.
fn window_zero_token(source : String) -> Bool {
  for unit in source {
    if unit == 'e' || unit == 'E' {
      return true
    }
    if unit != '0' && unit != '.' {
      return false
    }
  }
  true
}

///|
fn window_gate_frame(
  value : Json,
  max_tracks : Int32,
) -> @events.GateFrame raise @types.GroundError {
  let fields = object(value, "window source gate frame")
  allowed_fields(
    fields,
    [
      "schema_version", "kind", "session_id", "timestamp_us", "crossings", "counts",
      "event_scope",
    ],
    "window source gate frame",
  )
  if text(required(fields, "schema_version"), "schema_version") != "0.1.0" ||
    text(required(fields, "kind"), "kind") != "gate_events" ||
    text(required(fields, "event_scope"), "event_scope") !=
    "filtered_ground_positions" {
    raise invalid("unsupported window source gate frame")
  }
  {
    session_id: text(required(fields, "session_id"), "session_id"),
    timestamp_us: timestamp(required(fields, "timestamp_us"), "timestamp_us"),
    crossings: array(
      required(fields, "crossings"),
      "source gate crossings",
      max_tracks * 16,
    ).map(transit_crossing),
    counts: array(required(fields, "counts"), "source gate counts", 16).map(value => {
      let fields = object(value, "source gate count")
      allowed_fields(
        fields,
        ["gate_id", "negative_to_positive", "positive_to_negative"],
        "source gate count",
      )
      @events.GateCount::{
        gate_id: text(required(fields, "gate_id"), "gate_id"),
        negative_to_positive: timestamp(
          required(fields, "negative_to_positive"),
          "negative_to_positive",
        ),
        positive_to_negative: timestamp(
          required(fields, "positive_to_negative"),
          "positive_to_negative",
        ),
      }
    }),
  }
}

///|
fn window_evidence_frame(
  value : Json,
  max_tracks : Int32,
  multiplier : Double,
) -> @events.EvidenceGateFrame raise @types.GroundError {
  let fields = object(value, "window source evidence frame")
  allowed_fields(
    fields,
    [
      "schema_version", "kind", "counting", "evidence_scope", "sigma_multiplier",
      "evidence",
    ],
    "window source evidence frame",
  )
  if text(required(fields, "schema_version"), "schema_version") != "0.1.0" ||
    text(required(fields, "kind"), "kind") != "gate_evidence_frame" ||
    text(required(fields, "evidence_scope"), "evidence_scope") !=
    "normal_band_on_filtered_mean_chord" ||
    number(required(fields, "sigma_multiplier"), "sigma_multiplier") !=
    multiplier {
    raise invalid("window source evidence policy differs")
  }
  {
    counting: window_gate_frame(required(fields, "counting"), max_tracks),
    evidence: array(
      required(fields, "evidence"),
      "source gate evidence",
      max_tracks * 16,
    ).map(value => {
      let fields = object(value, "source evidence row")
      allowed_fields(
        fields,
        [
          "track_id", "segment_id", "gate_id", "distance_m", "normal_std_m", "lower_m",
          "upper_m", "side",
        ],
        "source evidence row",
      )
      @events.GateEvidence::{
        track_id: positive_int(required(fields, "track_id"), "track_id"),
        segment_id: text(required(fields, "segment_id"), "segment_id"),
        gate_id: text(required(fields, "gate_id"), "gate_id"),
        distance_m: number(required(fields, "distance_m"), "distance_m"),
        normal_std_m: number(required(fields, "normal_std_m"), "normal_std_m"),
        lower_m: number(required(fields, "lower_m"), "lower_m"),
        upper_m: number(required(fields, "upper_m"), "upper_m"),
        side: match text(required(fields, "side"), "side") {
          "positive" => 1
          "negative" => -1
          "unconfirmed" => 0
          _ => raise invalid("unknown source evidence side")
        },
      }
    }),
  }
}

///|
fn window_source_frame(
  source : String,
  max_tracks : Int32,
  multiplier : Double,
) -> @transit.EvidenceTransitFrame raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388608),
    "window source transit frame",
  )
  allowed_fields(
    fields,
    [
      "schema_version", "kind", "counting", "passages", "cancellations", "counts",
      "pending_count",
    ],
    "window source transit frame",
  )
  if text(required(fields, "schema_version"), "schema_version") != "0.1.0" ||
    text(required(fields, "kind"), "kind") != "evidence_transit_frame" {
    raise invalid("window input requires an original evidence transit frame")
  }
  let pending_value = required(fields, "pending_count")
  let pending = number(pending_value, "pending_count")
  if pending < 0.0 ||
    pending > 65536.0 ||
    pending.to_int().to_double() != pending ||
    (
      pending_value is Number(_, repr=Some(token)) &&
      !(if pending == 0.0 {
        window_zero_token(token)
      } else {
        integer_token_equals(token, pending.to_int())
      })
    ) {
    raise invalid("pending_count must be a nonnegative integer at most 65536")
  }
  {
    counting: window_evidence_frame(
      required(fields, "counting"),
      max_tracks,
      multiplier,
    ),
    passages: array(required(fields, "passages"), "source passages", 65536).map(value => {
        let fields = object(value, "source transit passage")
        allowed_fields(
          fields,
          [
            "section_id", "track_id", "segment_id", "entry", "exit", "elapsed_lower_us",
            "elapsed_upper_us", "estimated_elapsed_us",
          ],
          "source transit passage",
        )
        @transit.TransitPassage::{
          section_id: text(required(fields, "section_id"), "section_id"),
          track_id: positive_int(required(fields, "track_id"), "track_id"),
          segment_id: text(required(fields, "segment_id"), "segment_id"),
          entry: transit_crossing(required(fields, "entry")),
          exit: transit_crossing(required(fields, "exit")),
          elapsed_lower_us: timestamp(
            required(fields, "elapsed_lower_us"),
            "elapsed_lower_us",
          ),
          elapsed_upper_us: timestamp(
            required(fields, "elapsed_upper_us"),
            "elapsed_upper_us",
          ),
          estimated_elapsed_us: number(
            required(fields, "estimated_elapsed_us"),
            "estimated_elapsed_us",
          ),
        }
      },
    ),
    cancellations: array(
      required(fields, "cancellations"),
      "source cancellations",
      131072,
    ).map(value => {
      let fields = object(value, "source transit cancellation")
      allowed_fields(
        fields,
        ["section_id", "track_id", "segment_id", "reason", "entry"],
        "source transit cancellation",
      )
      @transit.TransitCancellation::{
        section_id: text(required(fields, "section_id"), "section_id"),
        track_id: positive_int(required(fields, "track_id"), "track_id"),
        segment_id: text(required(fields, "segment_id"), "segment_id"),
        reason: window_reason(required(fields, "reason")),
        entry: transit_crossing(required(fields, "entry")),
      }
    }),
    counts: window_counts(required(fields, "counts")),
    pending_count: pending.to_int(),
  }
}
