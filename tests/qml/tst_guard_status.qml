import QtQuick
import QtTest
import "../../lib/GuardStatus.js" as GuardStatus

TestCase {
  name: "GuardStatus"

  function record(disabled) {
    return JSON.stringify({ schemaVersion: 1, type: "guard", disabled: disabled })
  }

  function throws(text) {
    try {
      GuardStatus.parsePreflightRecord(text)
    } catch (error) {
      return true
    }
    return false
  }

  function padded(targetLength) {
    var prefix = '{"schemaVersion":1,"type":"guard","disabled":false,"pad":"'
    var count = targetLength - prefix.length - 2
    return prefix + new Array(count + 1).join("x") + '"}'
  }

  function test_valid_records_return_only_the_validated_field() {
    compare(GuardStatus.parsePreflightRecord(record(false)).disabled, false)
    compare(GuardStatus.parsePreflightRecord(record(true)).disabled, true)
    // Only the owned, validated field comes back - never the input's extras.
    var padded_record = '{"schemaVersion":1,"type":"guard","disabled":true,"error":"x","extra":[1]}'
    compare(Object.keys(GuardStatus.parsePreflightRecord(padded_record)).join(","), "disabled")
  }

  function test_input_is_bounded_before_parsing() {
    compare(GuardStatus.parsePreflightRecord(padded(4096)).disabled, false)
    verify(throws(padded(4097)))
    verify(throws(""))
    verify(throws(null))
    verify(throws(undefined))
    verify(throws(42))
  }

  function test_schema_version_and_type_tag_are_required() {
    verify(throws('{"type":"guard","disabled":false}'))
    verify(throws('{"schemaVersion":0,"type":"guard","disabled":false}'))
    verify(throws('{"schemaVersion":2,"type":"guard","disabled":false}'))
    verify(throws('{"schemaVersion":"1","type":"guard","disabled":false}'))
    verify(throws('{"schemaVersion":1,"disabled":false}'))
    // The helper's own error record must never read as a guard verdict.
    verify(throws('{"schemaVersion":1,"type":"error","error":"x"}'))
    verify(throws('{"schemaVersion":1,"type":"binding","disabled":false}'))
    verify(throws('{"schemaVersion":1,"type":"GUARD","disabled":false}'))
    verify(throws('{"schemaVersion":1,"type":1,"disabled":false}'))
  }

  function test_disabled_must_be_a_real_boolean() {
    verify(throws('{"schemaVersion":1,"type":"guard"}'))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":"false"}'))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":"true"}'))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":0}'))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":1}'))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":null}'))
  }

  function test_malformed_and_non_object_documents_throw() {
    verify(throws("{not json"))
    verify(throws('{"schemaVersion":1,"type":"guard","disabled":false} extra'))
    verify(throws("null"))
    verify(throws("[]"))
    verify(throws('[{"schemaVersion":1,"type":"guard","disabled":false}]'))
    verify(throws('"guard"'))
    verify(throws("1"))
    verify(throws("true"))
  }
}
