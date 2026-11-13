///|
fn evidence_transit_checkpoint_value(
  saved : @transit.EvidenceTransitCheckpoint,
) -> Json {
  Json::object({
    "format": Json("moonground.evidence-transit"),
    "checkpoint_version": Json("1"),
    "counting": evidence_checkpoint_value(saved.counting),
    "sections": transit_sections_json(saved.sections),
    "max_duration_us": Json(saved.max_duration_us.to_string()),
    "counts": transit_counts_json(saved.counts),
    "pending": Json(
      saved.pending.map(item => {
        Json::object({
          "section_id": Json(item.section_id),
          "entry": gate_crossing_json(item.entry),
          "from_covariance": covariance_json(item.from_covariance),
          "to_covariance": covariance_json(item.to_covariance),
        })
      }),
    ),
  })
}

///|
fn restore_evidence_transit_checkpoint(
  value : Json,
) -> @transit.EvidenceTransitCounter raise @types.GroundError {
  let fields = object(value, "evidence transit checkpoint")
  allowed_fields(
    fields,
    [
      "format", "checkpoint_version", "counting", "sections", "max_duration_us",
      "counts", "pending",
    ],
    "evidence transit checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.evidence-transit" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported evidence transit checkpoint format or version")
  }
  let counts = array(required(fields, "counts"), "evidence transit counts", 16).map(value => {
      let fields = object(value, "evidence transit count")
      allowed_fields(
        fields,
        ["section_id", "completed"],
        "evidence transit count",
      )
      @transit.TransitCount::{
        section_id: text(required(fields, "section_id"), "section_id"),
        completed: timestamp(required(fields, "completed"), "completed"),
      }
    },
  )
  let pending = array(
    required(fields, "pending"),
    "evidence transit pending",
    65536,
  ).map(value => {
    let fields = object(value, "evidence transit pending entry")
    allowed_fields(
      fields,
      ["section_id", "entry", "from_covariance", "to_covariance"],
      "evidence transit pending entry",
    )
    @transit.EvidenceTransitPending::{
      section_id: text(required(fields, "section_id"), "section_id"),
      entry: transit_crossing(required(fields, "entry")),
      from_covariance: covariance(required(fields, "from_covariance")),
      to_covariance: covariance(required(fields, "to_covariance")),
    }
  })
  @transit.EvidenceTransitCounter::from_checkpoint({
    version: 1,
    counting: restore_evidence_checkpoint(required(fields, "counting")).checkpoint(),
    sections: transit_sections(required(fields, "sections")),
    max_duration_us: timestamp(
      required(fields, "max_duration_us"),
      "max_duration_us",
    ),
    counts,
    pending,
  })
}

///|
fn evidence_transit_source(
  value : Json,
) -> @transit.EvidenceTransitCounter raise @types.GroundError {
  let fields = object(value, "evidence transit source")
  if fields.contains("resume") {
    allowed_fields(fields, ["resume"], "evidence transit resume source")
    let saved = required(fields, "resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence transit checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    return restore_evidence_transit_checkpoint(saved)
  }
  allowed_fields(
    fields,
    ["counting", "sections", "max_duration_us"],
    "evidence transit source",
  )
  let counting = text(required(fields, "counting"), "counting")
  @transit.EvidenceTransitCounter::new(
    evidence_source(parse_checkpoint_document(counting, max_units=8388619)),
    transit_sections(required(fields, "sections")),
    max_duration_us=match fields.get("max_duration_us") {
      Some(value) => timestamp(value, "max_duration_us")
      None => 300000000L
    },
  )
}
