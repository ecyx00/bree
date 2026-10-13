// Remote shell programs emit positive port rows plus completion markers for
// exactly the scan scopes that produced authoritative negative evidence.
extension RemoteSessionCoordinator {
    /// Builds the TTY-scoped remote listening-port scan program.
    static func remotePortScanScript(
        ttyNames: [String],
        excluding ports: Set<Int>,
        protecting protectedPortsByTTY: [String: Set<Int>]
    ) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")
        let protectedTTYPorts = protectedPortsByTTY.keys.sorted().flatMap { ttyName in
            (protectedPortsByTTY[ttyName] ?? []).sorted().map { "\(ttyName):\($0)" }
        }.joined(separator: " ")

        return """
        set -eu
        bree_tracked_ttys=" \(ttySet) "
        bree_tty_csv='\(ttyCSV)'
        bree_excluded_ports=" \(excludedPorts) "
        bree_protected_tty_ports=" \(protectedTTYPorts) "
        bree_scan_complete=0
        bree_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t bree-ports 2>/dev/null || true)"
        bree_global_incomplete=""
        bree_incomplete_ttys=""
        bree_tab="$(printf '\\t')"
        if [ -n "$bree_tmpdir" ]; then
          bree_global_incomplete="$bree_tmpdir/global-incomplete"
          bree_incomplete_ttys="$bree_tmpdir/incomplete-ttys"
          : > "$bree_incomplete_ttys"
          trap 'rm -rf "$bree_tmpdir"' EXIT INT TERM
        fi

        bree_mark_globally_incomplete() {
          [ -n "$bree_global_incomplete" ] && : > "$bree_global_incomplete"
          return 0
        }

        bree_mark_tty_incomplete() {
          bree_incomplete_tty="$1"
          case "$bree_tracked_ttys" in
            *" $bree_incomplete_tty "*) ;;
            *) return 0 ;;
          esac
          [ -n "$bree_incomplete_ttys" ] && printf '%s\\n' "$bree_incomplete_tty" >> "$bree_incomplete_ttys"
          return 0
        }

        bree_mark_port_owners_incomplete() {
          bree_ambiguous_port="$1"
          for bree_owner_tty in $bree_tracked_ttys; do
            case "$bree_protected_tty_ports" in
              *" $bree_owner_tty:$bree_ambiguous_port "*) bree_mark_tty_incomplete "$bree_owner_tty" ;;
            esac
          done
          return 0
        }

        bree_emit_port() {
          bree_tty="$1"
          bree_port="$2"
          case "$bree_tracked_ttys" in
            *" $bree_tty "*) ;;
            *) return 0 ;;
          esac
          case "$bree_excluded_ports" in
            *" $bree_port "*) return 0 ;;
          esac
          [ "$bree_port" -ge 1024 ] && [ "$bree_port" -le 65535 ] || return 0
          printf '%s\\t%s\\n' "$bree_tty" "$bree_port"
        }

        bree_used_ss=0
        if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
          bree_ss_status=0
          if [ -n "$bree_tmpdir" ]; then
            bree_ss_stderr="$bree_tmpdir/ss.stderr"
            bree_ss_output="$(ss -ltnpH 2>"$bree_ss_stderr")" || bree_ss_status=$?
            [ ! -s "$bree_ss_stderr" ] || bree_mark_globally_incomplete
          else
            bree_ss_output="$(ss -ltnpH 2>/dev/null)" || bree_ss_status=$?
            bree_mark_globally_incomplete
          fi
          [ "$bree_ss_status" -eq 0 ] || bree_mark_globally_incomplete
          case "$bree_ss_output" in
            "")
              if [ "$bree_ss_status" -eq 0 ]; then
                bree_used_ss=1
                bree_scan_complete=1
              fi
              ;;
            *pid=*)
              bree_used_ss=1
              [ "$bree_ss_status" -ne 0 ] || bree_scan_complete=1
              printf '%s\\n' "$bree_ss_output" | while IFS= read -r bree_line; do
                [ -n "$bree_line" ] || continue
                bree_port="$(printf '%s\\n' "$bree_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                if [ -z "$bree_port" ]; then bree_mark_globally_incomplete; continue; fi
                bree_pid_tokens="$(printf '%s\\n' "$bree_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[^,)]*/)) {
                      token = substr(line, RSTART, RLENGTH)
                      if (token ~ /^pid=[0-9]+$/) {
                        print substr(token, 5)
                      } else {
                        print "__bree_invalid_pid__"
                      }
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ')"
                if [ -z "$bree_pid_tokens" ]; then
                  bree_mark_port_owners_incomplete "$bree_port"
                  continue
                fi
                for bree_pid in $bree_pid_tokens; do
                  if [ "$bree_pid" = "__bree_invalid_pid__" ]; then
                    bree_mark_port_owners_incomplete "$bree_port"
                    continue
                  fi
                  bree_tty_path="$(readlink "/proc/$bree_pid/fd/0" 2>/dev/null || true)"
                  if [ -z "$bree_tty_path" ]; then bree_mark_port_owners_incomplete "$bree_port"; continue; fi
                  bree_tty="${bree_tty_path##*/}"
                  if [ -z "$bree_tty" ]; then bree_mark_port_owners_incomplete "$bree_port"; continue; fi
                  bree_emit_port "$bree_tty" "$bree_port"
                done
              done
              ;;
          esac
        fi

        if [ "$bree_used_ss" -eq 0 ] && [ -n "$bree_tmpdir" ] && command -v lsof >/dev/null 2>&1 && [ -n "$bree_tty_csv" ]; then
          rm -f "$bree_global_incomplete"
          : > "$bree_incomplete_ttys"
          bree_scan_complete=0
          bree_pid_tty_map="$bree_tmpdir/pid_tty"
          bree_ps_stderr="$bree_tmpdir/ps.stderr"
          bree_ps_status=0
          bree_ps_output="$(ps -t "$bree_tty_csv" -o pid=,tty= 2>"$bree_ps_stderr")" || bree_ps_status=$?
          if [ -s "$bree_ps_stderr" ]; then exit 0; fi
          # BSD ps exits 1 when a valid selector matches no processes.
          if [ "$bree_ps_status" -ne 0 ] && { [ "$bree_ps_status" -ne 1 ] || [ -n "$bree_ps_output" ]; }; then
            exit 0
          fi
          printf '%s\\n' "$bree_ps_output" | awk -v globally_incomplete="$bree_global_incomplete" '
            NF == 2 && $1 ~ /^[0-9]+$/ {
              tty = $2
              sub(/^.*\\//, "", tty)
              if (tty != "") {
                print $1 "\\t" tty
              } else {
                print "1" > globally_incomplete
                close(globally_incomplete)
              }
              next
            }
            NF > 0 {
              print "1" > globally_incomplete
              close(globally_incomplete)
            }
          ' > "$bree_pid_tty_map"
          if [ ! -s "$bree_pid_tty_map" ]; then bree_scan_complete=1; fi
          bree_pid_csv="$(awk '{print $1}' "$bree_pid_tty_map" | paste -sd, -)"
          if [ -n "$bree_pid_csv" ]; then
            bree_lsof_stderr="$bree_tmpdir/lsof.stderr"
            bree_lsof_status=0
            bree_lsof_output="$(lsof -nP -a -p "$bree_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>"$bree_lsof_stderr")" || bree_lsof_status=$?
            printf '%s\\n' "$bree_lsof_output" | awk \
              -v map="$bree_pid_tty_map" \
              -v globally_incomplete="$bree_global_incomplete" \
              -v incomplete_ttys="$bree_incomplete_ttys" '
              function mark_global() {
                print "1" > globally_incomplete
                close(globally_incomplete)
              }
              function mark_tty(value) {
                if (value != "") {
                  print value >> incomplete_ttys
                  close(incomplete_ttys)
                } else {
                  mark_global()
                }
              }
              BEGIN {
                while ((getline < map) > 0) {
                  pid_to_tty[$1] = $2
                }
                close(map)
              }
              $0 ~ /^p[0-9]+$/ {
                pid = substr($0, 2)
                tty = pid_to_tty[pid]
                if (tty == "") mark_global()
                next
              }
              $0 ~ /^p/ {
                tty = ""
                mark_global()
                next
              }
              $0 ~ /^n/ && tty != "" {
                name = substr($0, 2)
                sub(/->.*/, "", name)
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) {
                  print tty "\\t" name
                } else {
                  mark_tty(tty)
                }
                next
              }
              $0 ~ /^n/ { mark_global(); next }
              $0 ~ /^f.+$/ { next }
              NF > 0 { mark_tty(tty) }
            ' | while IFS="$bree_tab" read -r bree_tty bree_port; do
              [ -n "$bree_tty" ] || continue
              [ -n "$bree_port" ] || continue
              bree_emit_port "$bree_tty" "$bree_port"
            done
            if [ ! -s "$bree_lsof_stderr" ] && [ "$bree_lsof_status" -eq 0 ]; then
              bree_scan_complete=1
            elif [ ! -s "$bree_lsof_stderr" ] && [ "$bree_lsof_status" -eq 1 ]; then
              bree_scan_complete=1
              while IFS="$bree_tab" read -r bree_pid bree_tty; do
                kill -0 "$bree_pid" 2>/dev/null || bree_mark_tty_incomplete "$bree_tty"
              done < "$bree_pid_tty_map"
            else
              bree_mark_globally_incomplete
            fi
          fi
        fi
        if [ "$bree_scan_complete" -eq 1 ] && [ -n "$bree_global_incomplete" ] && [ ! -e "$bree_global_incomplete" ]; then
          for bree_complete_tty in $bree_tracked_ttys; do
            grep -F -x -e "$bree_complete_tty" "$bree_incomplete_ttys" >/dev/null 2>&1 && continue
            printf '%s\\t%s\\n' '\(remoteTTYPortScanCompleteMarker)' "$bree_complete_tty"
          done
        fi
        exit 0
        """
    }

    /// Builds the host-wide fallback listening-port scan program.
    static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        bree_excluded_ports=" \(excludedPorts) "
        bree_scan_output=""
        bree_scan_status=127
        bree_scanner=""
        bree_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t bree-ports 2>/dev/null || true)"
        bree_scan_stderr=""
        if [ -n "$bree_tmpdir" ]; then
          bree_scan_stderr="$bree_tmpdir/scanner.stderr"
          trap 'rm -rf "$bree_tmpdir"' EXIT INT TERM
        fi

        bree_emit_port() {
          bree_port="$1"
          case "$bree_excluded_ports" in
            *" $bree_port "*) return 0 ;;
          esac
          [ "$bree_port" -ge 1024 ] && [ "$bree_port" -le 65535 ] || return 0
          printf '%s\\n' "$bree_port"
        }

        bree_run_scanner() {
          bree_scan_status=0
          if [ -n "$bree_scan_stderr" ]; then
            bree_scan_output="$("$@" 2>"$bree_scan_stderr")" || bree_scan_status=$?
          else
            bree_scan_output="$("$@" 2>/dev/null)" || bree_scan_status=$?
          fi
        }

        if command -v ss >/dev/null 2>&1; then
          bree_scanner=ss
          bree_run_scanner ss -ltnH
        elif command -v netstat >/dev/null 2>&1; then
          bree_scanner=netstat
          bree_run_scanner netstat -lnt
        elif command -v lsof >/dev/null 2>&1; then
          bree_scanner=lsof
          bree_run_scanner lsof -nP -iTCP -sTCP:LISTEN
        fi

        bree_parsed_output=""
        case "$bree_scanner" in
          ss)
            bree_parsed_output="$(printf '%s\\n' "$bree_scan_output" | awk '
              NF == 0 { next }
              {
                name = $4
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__bree_incomplete__"
              }
            ')"
            ;;
          netstat)
            bree_parsed_output="$(printf '%s\\n' "$bree_scan_output" | awk '
              NF == 0 || $1 == "Proto" || /^Active Internet/ { next }
              {
                name = $4
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__bree_incomplete__"
              }
            ')"
            ;;
          lsof)
            bree_parsed_output="$(printf '%s\\n' "$bree_scan_output" | awk '
              NF == 0 || $1 == "COMMAND" { next }
              {
                name = $9
                sub(/->.*/, "", name)
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__bree_incomplete__"
              }
            ')"
            ;;
        esac

        bree_parse_complete=1
        case "$bree_parsed_output" in
          *__bree_incomplete__*) bree_parse_complete=0 ;;
        esac
        printf '%s\\n' "$bree_parsed_output" | while IFS= read -r bree_port; do
          [ -n "$bree_port" ] || continue
          [ "$bree_port" != "__bree_incomplete__" ] || continue
          bree_emit_port "$bree_port"
        done

        bree_command_complete=0
        if [ -n "$bree_scan_stderr" ] && [ ! -s "$bree_scan_stderr" ]; then
          if [ "$bree_scan_status" -eq 0 ]; then
            bree_command_complete=1
          elif [ "$bree_scanner" = lsof ] && [ "$bree_scan_status" -eq 1 ] && [ -z "$bree_scan_output" ]; then
            bree_command_complete=1
          fi
        fi
        if [ "$bree_command_complete" -eq 1 ] && [ "$bree_parse_complete" -eq 1 ]; then
          printf '%s\\n' '\(remotePortScanCompleteMarker)'
        fi
        exit 0
        """
    }
}
