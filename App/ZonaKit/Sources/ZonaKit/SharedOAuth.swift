// The OAuth/token plumbing and the Strava/WHOOP DTOs moved to HealthConnectKit,
// a package shared with the Helix aggregator. They are re-exported here so
// `import ZonaKit` still sees them: the app target uses `TokenStore`,
// `TokenRefresher`, `StravaOAuth`, `WhoopOAuth` and the token/DTO types
// throughout, and every one of those call sites is unchanged by the move.
//
// This is a deliberate convenience, not an accident — dropping it would force a
// second `import HealthConnectKit` into ~8 app-target files to no benefit, since
// an app that imports ZonaKit always wants the providers too.
//
// `WhoopReadiness` (which stays here) also depends on `WhoopRecovery` from that
// package for its `init(from:)`, so the re-export keeps ZonaKit's own public API
// self-contained: a caller constructing a readiness from a recovery record
// doesn't need to know the type crossed a package boundary.
@_exported import HealthConnectKit
