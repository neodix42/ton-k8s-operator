package controller

import (
	"reflect"
	"strings"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

func TestInstallationArgsTokenization(t *testing.T) {
	for _, tt := range []struct {
		name  string
		value string
		want  []string
		fail  bool
	}{
		{name: "empty", value: " \t\r\n "},
		{name: "quoted values", value: "-c '/config/a b.json' -p \"/backup/with space.tar.gz\"", want: []string{"-c", "/config/a b.json", "-p", "/backup/with space.tar.gz"}},
		{name: "escaped space", value: "-c /config/a\\ b.json", want: []string{"-c", "/config/a b.json"}},
		{name: "adjacent quoted fragments", value: "root\"ed\"'value'", want: []string{"rootedvalue"}},
		{name: "empty argument", value: "-c ''", want: []string{"-c", ""}},
		{name: "single quotes retain escape", value: "'a\\b'", want: []string{"a\\b"}},
		{name: "double quote escaping matches shlex", value: "\"a\\ b\\$c\\\"d\\\\e\"", want: []string{"a\\ b\\$c\"d\\e"}},
		{name: "substitutions and comments are literal", value: "'$(touch /tmp/unwanted)' '$HOME' '# literal'", want: []string{"$(touch /tmp/unwanted)", "$HOME", "# literal"}},
		{name: "unterminated quote", value: "-m 'validator", fail: true},
		{name: "trailing escape", value: "-m validator\\", fail: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := splitInstallationArgs(tt.value)
			if (err != nil) != tt.fail {
				t.Fatalf("split error=%v, want error=%t", err, tt.fail)
			}
			if !tt.fail && !reflect.DeepEqual(got, tt.want) {
				t.Errorf("tokens=%q, want %q", got, tt.want)
			}
		})
	}
}

func TestInstallationArgsValidateFinalTopology(t *testing.T) {
	for _, tt := range []struct {
		name      string
		literal   string
		args      []string
		env       []corev1.EnvVar
		keyMgmt   bool
		wantError string
	}{
		{name: "default full node"},
		{name: "mainnet validator flags", literal: "-m validator -n mainnet -d -i -s"},
		{name: "quoted backup and network", literal: "-m liteserver -n custom -c 'https://example.test/-exporter?a=with space' -p '/backup/my node.tar.gz' -t"},
		{name: "grouped boolean flags", args: []string{"-ids", "-m", "collator"}},
		{name: "work short value", args: []string{"-W", "/var/ton-work"}},
		{name: "work short attached", args: []string{"-W/var/ton-work"}},
		{name: "work short equals", args: []string{"-W=/var/ton-work"}},
		{name: "work long value", args: []string{"--ton-work-dir", "/var/ton-work"}},
		{name: "work long equals", args: []string{"--ton-work-dir=/var/ton-work"}},
		{name: "final argv overrides environment flags", literal: "-W /previous -u customuser", args: []string{"-W", "/var/ton-work", "-u", "root"}, keyMgmt: true},
		{name: "final repeated user", args: []string{"-u", "customuser", "--user=validator"}, keyMgmt: true},
		{name: "final repeated work", args: []string{"-W/data", "--ton-work-dir=/var/ton-work"}},
		{name: "args override work environment", env: []corev1.EnvVar{{Name: "TON_WORK_DIR", Value: "/old"}}, args: []string{"-W/var/ton-work"}},
		{name: "different short work", args: []string{"-W", "/data"}, wantError: "/var/ton-work"},
		{name: "different attached short work", args: []string{"-W/data"}, wantError: "/var/ton-work"},
		{name: "different equals short work", args: []string{"-W=/data"}, wantError: "/var/ton-work"},
		{name: "different long work", args: []string{"--ton-work-dir=/data"}, wantError: "/var/ton-work"},
		{name: "different grouped short work", args: []string{"-idW/data"}, wantError: "/var/ton-work"},
		{name: "later work value wins", literal: "-W /var/ton-work", args: []string{"-W/data"}, wantError: "/var/ton-work"},
		{name: "work via environment flags", literal: "'-W' '/data'", wantError: "/var/ton-work"},
		{name: "work via environment value", env: []corev1.EnvVar{{Name: "TON_WORK_DIR", Value: "/data"}}, wantError: "/var/ton-work"},
		{name: "missing value", args: []string{"-W"}, wantError: "requires a value"},
		{name: "next option is not a value", args: []string{"-W", "-i"}, wantError: "requires a value"},
		{name: "environment file short", args: []string{"-e", "/config/settings.env"}, wantError: "env-file"},
		{name: "environment file attached", args: []string{"-e/config/settings.env"}, wantError: "env-file"},
		{name: "environment file equals", args: []string{"-e=/config/settings.env"}, wantError: "env-file"},
		{name: "environment file grouped", args: []string{"-ide/config/settings.env"}, wantError: "env-file"},
		{name: "environment file long", literal: "--env-file=/config/settings.env", wantError: "env-file"},
		{name: "node only short", args: []string{"-l"}, wantError: "both local"},
		{name: "node only grouped", args: []string{"-idl"}, wantError: "both local"},
		{name: "controller only short", args: []string{"-o", "-p", "/backup/node.tar.gz"}, wantError: "both local"},
		{name: "node only long", literal: "--only-node", wantError: "both local"},
		{name: "controller only long", literal: "--only-mtc -p /backup/node.tar.gz", wantError: "both local"},
		{name: "node only environment", env: []corev1.EnvVar{{Name: "ONLY_NODE", Value: "YES"}}, wantError: "ONLY_NODE"},
		{name: "controller only environment", env: []corev1.EnvVar{{Name: "ONLY_MTC", Value: "1"}}, wantError: "ONLY_MTC"},
		{name: "split modes disabled", env: []corev1.EnvVar{{Name: "ONLY_NODE", Value: "false"}, {Name: "ONLY_MTC", Value: "no"}}},
		{name: "help short", args: []string{"-h"}, wantError: "exits without"},
		{name: "help long", args: []string{"--help"}, wantError: "exits without"},
		{name: "help grouped", args: []string{"-idh"}, wantError: "exits without"},
		{name: "help in literal flags", literal: "-m validator --help", wantError: "exits without"},
		{name: "print environment flag", args: []string{"--print-env"}, wantError: "exits without"},
		{name: "print environment variable", env: []corev1.EnvVar{{Name: "MYTONCTRL_PRINT_ENV", Value: "true"}}, wantError: "exits without"},
		{name: "print environment variable numeric", env: []corev1.EnvVar{{Name: "MYTONCTRL_PRINT_ENV", Value: "1"}}, wantError: "exits without"},
		{name: "archive flag", args: []string{"-m", "liteserver", "--archive"}, wantError: "tonutils-storage"},
		{name: "archive environment", env: []corev1.EnvVar{{Name: "ARCHIVE", Value: "true"}}, wantError: "tonutils-storage"},
		{name: "archive environment affirmative", env: []corev1.EnvVar{{Name: "ARCHIVE", Value: "YES"}}, wantError: "tonutils-storage"},
		{name: "archive blocks", env: []corev1.EnvVar{{Name: "ARCHIVE_BLOCKS", Value: "1"}}, wantError: "tonutils-storage"},
		{name: "archive blocks zero is still nonempty", env: []corev1.EnvVar{{Name: "ARCHIVE_BLOCKS", Value: "0"}}, wantError: "tonutils-storage"},
		{name: "archive blocks disabled", env: []corev1.EnvVar{{Name: "ARCHIVE_BLOCKS", Value: ""}}},
		{name: "archive and print disabled false", env: []corev1.EnvVar{{Name: "ARCHIVE", Value: "false"}, {Name: "MYTONCTRL_PRINT_ENV", Value: "false"}}},
		{name: "archive and print disabled zero", env: []corev1.EnvVar{{Name: "ARCHIVE", Value: "0"}, {Name: "MYTONCTRL_PRINT_ENV", Value: "0"}}},
		{name: "archive and print disabled no", env: []corev1.EnvVar{{Name: "ARCHIVE", Value: "no"}, {Name: "MYTONCTRL_PRINT_ENV", Value: "NO"}}},
		{name: "custom user without encryption", args: []string{"-ucustomuser"}},
		{name: "root with encryption", args: []string{"--user=root"}, keyMgmt: true},
		{name: "validator with encryption", literal: "-u validator", keyMgmt: true},
		{name: "other user with encryption", args: []string{"-u=customuser"}, keyMgmt: true, wantError: "root or validator"},
		{name: "environment user with encryption", env: []corev1.EnvVar{{Name: "MTC_USER", Value: "customuser"}}, keyMgmt: true, wantError: "root or validator"},
		{name: "unknown flag", args: []string{"--not-an-installer-flag"}, wantError: "unsupported"},
		{name: "source flag", args: []string{"-bmaster"}, wantError: "selects sources"},
		{name: "source long flag", literal: "--node-version=master", wantError: "selects sources"},
		{name: "bad literal quoting", literal: "-m 'validator", wantError: "invalid quoting"},
		{name: "flag does not accept value", args: []string{"--dump=true"}, wantError: "does not accept a value"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{Args: tt.args, Env: tt.env}}
			if tt.literal != "" {
				node.Spec.Env = append(node.Spec.Env, corev1.EnvVar{Name: "MYTONCTRL_ARGS", Value: tt.literal})
			}
			if tt.keyMgmt {
				node.Spec.KeyManagement = &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true}
			}
			message := validateInstallationArgs(node)
			if tt.wantError == "" && message != "" {
				t.Errorf("unexpected rejection: %s", message)
			}
			if tt.wantError != "" && !strings.Contains(message, tt.wantError) {
				t.Errorf("rejection=%q, want %q", message, tt.wantError)
			}
		})
	}
}

func TestInstallationArgsValidateDynamicTopology(t *testing.T) {
	for _, tt := range []struct {
		name      string
		variable  string
		args      []string
		keyMgmt   bool
		wantError bool
	}{
		{name: "dynamic flags", variable: "MYTONCTRL_ARGS", wantError: true},
		{name: "dynamic work path", variable: "TON_WORK_DIR", wantError: true},
		{name: "dynamic work path overridden", variable: "TON_WORK_DIR", args: []string{"-W", "/var/ton-work"}},
		{name: "dynamic node only", variable: "ONLY_NODE", wantError: true},
		{name: "dynamic controller only", variable: "ONLY_MTC", wantError: true},
		{name: "dynamic print environment", variable: "MYTONCTRL_PRINT_ENV", wantError: true},
		{name: "dynamic archive", variable: "ARCHIVE", wantError: true},
		{name: "dynamic archive blocks", variable: "ARCHIVE_BLOCKS", wantError: true},
		{name: "dynamic user without encryption", variable: "MTC_USER"},
		{name: "dynamic user with encryption", variable: "MTC_USER", keyMgmt: true, wantError: true},
		{name: "dynamic user overridden with encryption", variable: "MTC_USER", args: []string{"-u", "root"}, keyMgmt: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{
				Args: tt.args,
				Env: []corev1.EnvVar{{Name: tt.variable, ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "runtime"}, Key: tt.variable},
				}}},
			}}
			if tt.keyMgmt {
				node.Spec.KeyManagement = &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true}
			}
			message := validateInstallationArgs(node)
			if (message != "") != tt.wantError {
				t.Errorf("validation=%q, want rejection=%t", message, tt.wantError)
			}
		})
	}
}
