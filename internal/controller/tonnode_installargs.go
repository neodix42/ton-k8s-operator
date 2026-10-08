package controller

import (
	"fmt"
	"strings"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

// splitInstallationArgs matches Python shlex.split's quote and escape handling.
// Arguments are data: substitutions, variables and comments are never executed.
func splitInstallationArgs(value string) ([]string, error) {
	var result []string
	var token strings.Builder
	var quote rune
	started := false
	characters := []rune(value)
	for index := 0; index < len(characters); index++ {
		character := characters[index]
		if quote == '\'' {
			if character == '\'' {
				quote = 0
			} else {
				token.WriteRune(character)
			}
			continue
		}
		if character == '\\' {
			if index+1 == len(characters) {
				return nil, fmt.Errorf("trailing escape")
			}
			index++
			next := characters[index]
			// shlex retains escapes for characters other than backslash and
			// double quote inside a double-quoted string.
			if quote == '"' && next != '\\' && next != '"' {
				token.WriteRune('\\')
			}
			token.WriteRune(next)
			started = true
			continue
		}
		if quote == '"' {
			if character == '"' {
				quote = 0
			} else {
				token.WriteRune(character)
			}
			continue
		}
		switch character {
		case '\'', '"':
			quote = character
			started = true
		case ' ', '\t', '\n', '\r':
			if started {
				result = append(result, token.String())
				token.Reset()
				started = false
			}
		default:
			token.WriteRune(character)
			started = true
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("unclosed quote")
	}
	if started {
		result = append(result, token.String())
	}
	return result, nil
}

func validateInstallationArgs(node *tonv1alpha1.TonNode) string {
	environment := make(map[string]corev1.EnvVar, len(node.Spec.Env))
	for _, variable := range node.Spec.Env {
		environment[variable.Name] = variable
	}
	var args []string
	if variable, exists := environment["MYTONCTRL_ARGS"]; exists {
		if variable.ValueFrom != nil {
			return "spec.env MYTONCTRL_ARGS must be literal so the operator can validate storage paths and node services"
		}
		var err error
		args, err = splitInstallationArgs(variable.Value)
		if err != nil {
			return fmt.Sprintf("spec.env MYTONCTRL_ARGS contains invalid quoting: %v", err)
		}
	}
	args = append(args, node.Spec.Args...)

	// Upstream applies the environment first, then MYTONCTRL_ARGS, then the
	// explicit container argv. Repeated value options use the last occurrence.
	work, workDynamic := installationEnvValue(environment, "TON_WORK_DIR", "/var/ton-work")
	user, userDynamic := installationEnvValue(environment, "MTC_USER", "root")
	for _, name := range []string{"ONLY_NODE", "ONLY_MTC"} {
		if variable, exists := environment[name]; exists {
			if variable.ValueFrom != nil {
				return fmt.Sprintf("spec.env %s must be literal; this operator requires both local validator and MyTonCtrl services", name)
			}
			switch strings.ToLower(variable.Value) {
			case "false", "0", "no":
			case "true", "1", "yes":
				return fmt.Sprintf("spec.env %s is unsupported; this operator requires both local validator and MyTonCtrl services", name)
			default:
				return fmt.Sprintf("spec.env %s must be a boolean (true/false, 1/0 or yes/no)", name)
			}
		}
	}
	for _, restriction := range []struct {
		name   string
		reason string
	}{
		{"MYTONCTRL_PRINT_ENV", "prints settings and exits without starting the node services"},
		{"ARCHIVE", "requires an extra tonutils-storage executable that the standard official TON image does not provide"},
	} {
		if variable, exists := environment[restriction.name]; exists {
			if variable.ValueFrom != nil {
				return fmt.Sprintf("spec.env %s must be literal and disabled; it %s", restriction.name, restriction.reason)
			}
			switch strings.ToLower(variable.Value) {
			case "false", "0", "no":
			case "true", "1", "yes":
				return fmt.Sprintf("spec.env %s is unsupported; it %s", restriction.name, restriction.reason)
			default:
				return fmt.Sprintf("spec.env %s must be a boolean (true/false, 1/0 or yes/no)", restriction.name)
			}
		}
	}
	if variable, exists := environment["ARCHIVE_BLOCKS"]; exists && (variable.ValueFrom != nil || variable.Value != "") {
		return "spec.env ARCHIVE_BLOCKS is unsupported; it requires an extra tonutils-storage executable that the standard official TON image does not provide"
	}

	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--" && index == len(args)-1 {
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" || arg == "--" {
			return fmt.Sprintf("unexpected installation argument %q; spec.args contains MyTonCtrl installer flags after run", arg)
		}
		if strings.HasPrefix(arg, "--") {
			name, value, attached := strings.Cut(strings.TrimPrefix(arg, "--"), "=")
			switch name {
			case "only-node", "only-mtc":
				return fmt.Sprintf("--%s is unsupported; this operator requires both local validator and MyTonCtrl services", name)
			case "env-file":
				return "--env-file is unsupported; use spec.env so storage paths can be validated"
			case "author", "repo", "branch", "node-repo", "node-version":
				return fmt.Sprintf("--%s selects sources; select spec.image or spec.tonImage instead", name)
			case "help", "print-env":
				return fmt.Sprintf("--%s is unsupported in a TonNode; it exits without starting the node services", name)
			case "archive":
				return "--archive is unsupported; it requires an extra tonutils-storage executable that the standard official TON image does not provide"
			case "telemetry", "ignore-reqs", "dump", "no-startup-checks":
				if attached {
					return fmt.Sprintf("--%s is a flag and does not accept a value", name)
				}
				continue
			case "mode", "network", "config", "user", "backup", "bin-dir", "src-dir", "ton-work-dir":
				if !attached {
					var errorMessage string
					value, errorMessage = installationOptionValue(args, &index, arg)
					if errorMessage != "" {
						return errorMessage
					}
				}
			default:
				return fmt.Sprintf("unsupported MyTonCtrl installation option %q", arg)
			}
			if name == "ton-work-dir" {
				work, workDynamic = value, false
			}
			if name == "user" {
				user, userDynamic = value, false
			}
			continue
		}

		// argparse supports groups of short flags, including -idW/data.
		for position := 1; position < len(arg); position++ {
			name := arg[position]
			switch name {
			case 'o', 'l':
				return fmt.Sprintf("-%c is unsupported; this operator requires both local validator and MyTonCtrl services", name)
			case 'e':
				return "-e/--env-file is unsupported; use spec.env so storage paths can be validated"
			case 'a', 'r', 'b', 'g', 'v':
				return fmt.Sprintf("-%c selects sources; select spec.image or spec.tonImage instead", name)
			case 'h':
				return "-h/--help is unsupported in a TonNode; it exits without starting the node services"
			case 't', 'i', 'd', 's':
				continue
			case 'm', 'n', 'c', 'u', 'p', 'B', 'S', 'W':
				value := strings.TrimPrefix(arg[position+1:], "=")
				if position == len(arg)-1 {
					var errorMessage string
					value, errorMessage = installationOptionValue(args, &index, "-"+string(name))
					if errorMessage != "" {
						return errorMessage
					}
				}
				if name == 'W' {
					work, workDynamic = value, false
				}
				if name == 'u' {
					user, userDynamic = value, false
				}
				position = len(arg)
			default:
				return fmt.Sprintf("unsupported MyTonCtrl installation option -%c", name)
			}
		}
	}
	if workDynamic {
		return "spec.env TON_WORK_DIR must be literal or overridden by --ton-work-dir=/var/ton-work"
	}
	if work != "/var/ton-work" {
		return "MyTonCtrl --ton-work-dir/TON_WORK_DIR must remain /var/ton-work for the operator's storage, probes and key management"
	}
	if keyManagementEnabled(node) {
		if userDynamic {
			return "spec.env MTC_USER must be literal when key management is enabled"
		}
		if user != "root" && user != "validator" {
			return "MyTonCtrl -u/--user/MTC_USER must be root or validator when key management is enabled so restored client keys remain readable"
		}
	}
	return ""
}

func installationEnvValue(environment map[string]corev1.EnvVar, name, fallback string) (string, bool) {
	if variable, exists := environment[name]; exists {
		return variable.Value, variable.ValueFrom != nil
	}
	return fallback, false
}

func installationOptionValue(args []string, index *int, option string) (string, string) {
	if *index+1 >= len(args) || strings.HasPrefix(args[*index+1], "-") {
		return "", fmt.Sprintf("%s requires a value", option)
	}
	*index++
	return args[*index], ""
}
