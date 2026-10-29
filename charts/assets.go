// Package charts exposes runtime helpers shared by the operator and kubeton.
package charts

import _ "embed"

// FleetScript is the same recovery implementation shipped with kubeton.
//
//go:embed ton-k8s-operator/fleet.py
var FleetScript string

// JemallocProfileScript enables persistent diagnostic allocation profiles.
//
//go:embed ton-k8s-operator/jemalloc-profile.py
var JemallocProfileScript string
