# shellcheck shell=bash
# NetworkManager operations shared by the text and graphical installers.

KIBAOS_WIFI_NMCLI=${KIBAOS_NMCLI:-nmcli}
KIBAOS_WIFI_PROFILE_DIR=${KIBAOS_NM_PROFILE_DIR:-/etc/NetworkManager/system-connections}
KIBAOS_WIFI_ERROR=
KIBAOS_WIFI_FIELDS=()
KIBAOS_WIFI_SSIDS=()
KIBAOS_WIFI_SIGNALS=()
KIBAOS_WIFI_SECURITY=()
KIBAOS_WIFI_AUTH=()
KIBAOS_WIFI_OPEN=()
KIBAOS_WIFI_ACTIVE=()
KIBAOS_WIFI_SAVED=()
KIBAOS_WIFI_SAVED_NAMES=()
KIBAOS_WIFI_SAVED_UUIDS=()
KIBAOS_WIFI_SAVED_CARRIED=()

kibaos_wifi_available() { command -v "$KIBAOS_WIFI_NMCLI" >/dev/null 2>&1; }

# nmcli escapes both colons and backslashes in terse output.
kibaos_wifi_fields() {
  local line=$1 field='' i c
  KIBAOS_WIFI_FIELDS=()
  for (( i = 0; i < ${#line}; i++ )); do
    c=${line:i:1}
    if [[ $c == "\\" && $(( i + 1 )) -lt ${#line} ]]; then
      i=$(( i + 1 ))
      field+=${line:i:1}
    elif [[ $c == ':' ]]; then
      KIBAOS_WIFI_FIELDS+=("$field")
      field=''
    else
      field+=$c
    fi
  done
  KIBAOS_WIFI_FIELDS+=("$field")
}

kibaos_wifi_status() {
  local line
  KIBAOS_WIFI_AVAILABLE=false
  KIBAOS_WIFI_WIRED=false
  KIBAOS_WIFI_WIFI=false
  KIBAOS_WIFI_RADIO=unavailable
  KIBAOS_WIFI_SSID=
  KIBAOS_WIFI_CONNECTIVITY=
  kibaos_wifi_available || return 0
  KIBAOS_WIFI_AVAILABLE=true
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    kibaos_wifi_fields "$line"
    case ${KIBAOS_WIFI_FIELDS[1]:-} in
      ethernet) [[ ${KIBAOS_WIFI_FIELDS[2]:-} != connected ]] || KIBAOS_WIFI_WIRED=true ;;
      wifi)
        KIBAOS_WIFI_WIFI=true
        if [[ ${KIBAOS_WIFI_FIELDS[2]:-} == connected ]]; then
          KIBAOS_WIFI_SSID=${KIBAOS_WIFI_FIELDS[3]:-}
        fi ;;
    esac
  done < <("$KIBAOS_WIFI_NMCLI" -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || true)
  KIBAOS_WIFI_RADIO=$("$KIBAOS_WIFI_NMCLI" -t radio wifi 2>/dev/null || printf 'unavailable')
  [[ -n $KIBAOS_WIFI_RADIO ]] || KIBAOS_WIFI_RADIO=unavailable
  KIBAOS_WIFI_CONNECTIVITY=$("$KIBAOS_WIFI_NMCLI" -t -f CONNECTIVITY general status 2>/dev/null | head -1 || true)
}

kibaos_wifi_saved() {
  local want=$1 line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    kibaos_wifi_fields "$line"
    case ${KIBAOS_WIFI_FIELDS[1]:-} in 802-11-wireless|wifi) ;; *) continue ;; esac
    [[ ${KIBAOS_WIFI_FIELDS[0]:-} != "$want" ]] || return 0
  done < <("$KIBAOS_WIFI_NMCLI" -t -f NAME,TYPE connection show 2>/dev/null || true)
  return 1
}

kibaos_wifi_saved_profiles() {
  local listing line name uuid type profile index
  KIBAOS_WIFI_SAVED_NAMES=()
  KIBAOS_WIFI_SAVED_UUIDS=()
  KIBAOS_WIFI_SAVED_CARRIED=()
  KIBAOS_WIFI_ERROR=
  if ! kibaos_wifi_available; then
    KIBAOS_WIFI_ERROR='NetworkManager is not on this image'
    return 1
  fi
  if ! listing=$("$KIBAOS_WIFI_NMCLI" -t -f NAME,UUID,TYPE connection show 2>/dev/null); then
    KIBAOS_WIFI_ERROR='Saved networks could not be listed.'
    return 1
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    kibaos_wifi_fields "$line"
    name=${KIBAOS_WIFI_FIELDS[0]:-}
    uuid=${KIBAOS_WIFI_FIELDS[1]:-}
    type=${KIBAOS_WIFI_FIELDS[2]:-}
    [[ $type == wifi || $type == 802-11-wireless ]] || continue
    [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || continue
    index=${#KIBAOS_WIFI_SAVED_NAMES[@]}
    KIBAOS_WIFI_SAVED_NAMES[index]=$name
    KIBAOS_WIFI_SAVED_UUIDS[index]=$uuid
    KIBAOS_WIFI_SAVED_CARRIED[index]=false
    profile="$KIBAOS_WIFI_PROFILE_DIR/kibaos-${uuid,,}.nmconnection"
    [[ ! -f $profile || -L $profile ]] || KIBAOS_WIFI_SAVED_CARRIED[index]=true
  done <<<"$listing"
  return 0
}

kibaos_wifi_activate_profile() {
  local uuid=$1 output
  KIBAOS_WIFI_ERROR=
  if [[ ! $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    KIBAOS_WIFI_ERROR='That saved network is no longer available.'
    return 1
  fi
  if output=$("$KIBAOS_WIFI_NMCLI" connection up uuid "$uuid" 2>&1); then
    return 0
  fi
  KIBAOS_WIFI_ERROR=$(kibaos_wifi_reason "$output" '')
  return 1
}

kibaos_wifi_forget_profile() {
  local uuid=$1 profile
  KIBAOS_WIFI_ERROR=
  if [[ ! $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    KIBAOS_WIFI_ERROR='That saved network is no longer available.'
    return 1
  fi
  if ! "$KIBAOS_WIFI_NMCLI" connection delete uuid "$uuid" >/dev/null 2>&1; then
    KIBAOS_WIFI_ERROR='Could not forget that network.'
    return 1
  fi
  profile="$KIBAOS_WIFI_PROFILE_DIR/kibaos-${uuid,,}.nmconnection"
  if [[ -f $profile && ! -L $profile ]] && ! rm -f -- "$profile"; then
    KIBAOS_WIFI_ERROR='The network was removed, but its local profile could not be cleared.'
    return 1
  fi
  return 0
}

kibaos_wifi_classify() {
  local security=${1^^}
  case $security in
    ''|--) KIBAOS_WIFI_KIND=open ;;
    *802.1X*|*EAP*|*ENTERPRISE*) KIBAOS_WIFI_KIND=enterprise ;;
    *WEP*) KIBAOS_WIFI_KIND=legacy ;;
    *OWE*) KIBAOS_WIFI_KIND=owe ;;
    *WPA3*)
      if [[ $security == *WPA1* || $security == *WPA2* ]]; then
        KIBAOS_WIFI_KIND=wpa-psk
      else
        KIBAOS_WIFI_KIND=sae
      fi ;;
    *WPA*) KIBAOS_WIFI_KIND=wpa-psk ;;
    *) KIBAOS_WIFI_KIND=unknown ;;
  esac
}

kibaos_wifi_scan() {
  local listing line ssid signal security active index found
  KIBAOS_WIFI_SSIDS=()
  KIBAOS_WIFI_SIGNALS=()
  KIBAOS_WIFI_SECURITY=()
  KIBAOS_WIFI_AUTH=()
  KIBAOS_WIFI_OPEN=()
  KIBAOS_WIFI_ACTIVE=()
  KIBAOS_WIFI_SAVED=()
  if ! kibaos_wifi_available; then
    KIBAOS_WIFI_ERROR='NetworkManager is not on this image'
    return 1
  fi
  "$KIBAOS_WIFI_NMCLI" device wifi rescan >/dev/null 2>&1 || true
  if ! listing=$("$KIBAOS_WIFI_NMCLI" -t -f SSID,SIGNAL,SECURITY,IN-USE device wifi list 2>/dev/null); then
    KIBAOS_WIFI_ERROR='Wi-Fi could not be scanned. Turn it on or connect a cable.'
    return 1
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    kibaos_wifi_fields "$line"
    ssid=${KIBAOS_WIFI_FIELDS[0]:-}
    [[ -n $ssid ]] || continue
    signal=${KIBAOS_WIFI_FIELDS[1]:-0}
    [[ $signal =~ ^[0-9]{1,3}$ ]] || signal=0
    signal=$(( 10#$signal ))
    (( signal <= 100 )) || signal=100
    security=${KIBAOS_WIFI_FIELDS[2]:-}
    active=${KIBAOS_WIFI_FIELDS[3]:-no}
    found=-1
    for index in "${!KIBAOS_WIFI_SSIDS[@]}"; do
      if [[ ${KIBAOS_WIFI_SSIDS[index]} == "$ssid" ]]; then
        found=$index
        break
      fi
    done
    if (( found >= 0 )); then
      if [[ $active == yes || $active == '*' ]]; then
        KIBAOS_WIFI_ACTIVE[found]=true
      fi
      if (( signal <= KIBAOS_WIFI_SIGNALS[found] )); then
        continue
      fi
    fi
    if (( found < 0 )); then
      found=${#KIBAOS_WIFI_SSIDS[@]}
    fi
    KIBAOS_WIFI_SSIDS[found]=$ssid
    KIBAOS_WIFI_SIGNALS[found]=$signal
    KIBAOS_WIFI_SECURITY[found]=$security
    kibaos_wifi_classify "$security"
    KIBAOS_WIFI_AUTH[found]=$KIBAOS_WIFI_KIND
    KIBAOS_WIFI_OPEN[found]=false
    [[ -n $security && $security != -- ]] || KIBAOS_WIFI_OPEN[found]=true
    KIBAOS_WIFI_ACTIVE[found]=${KIBAOS_WIFI_ACTIVE[found]:-false}
    [[ $active != yes && $active != '*' ]] || KIBAOS_WIFI_ACTIVE[found]=true
    KIBAOS_WIFI_SAVED[found]=false
    kibaos_wifi_saved "$ssid" && KIBAOS_WIFI_SAVED[found]=true
  done <<<"$listing"
  KIBAOS_WIFI_ERROR=
  return 0
}

kibaos_wifi_reason() {
  local message=${1,,} psk=$2
  case $message in
    *'secrets were required'*|*'no secrets'*|*'802.1x supplicant'*)
      if [[ -n $psk ]]; then
        printf '%s' 'That password was not accepted. Check it and try again.'
      else
        printf '%s' 'This network needs a password.'
      fi ;;
    *timeout*|*'timed out'*)
      printf '%s' 'The network did not answer in time. Move closer to the router, or try again.' ;;
    *'not authorized'*|*'not permitted'*)
      printf '%s' 'This session is not allowed to change network settings.' ;;
    *'no network with ssid'*|*'not found'*)
      printf '%s' 'That network is no longer in range.' ;;
    *)
      printf '%s' 'Could not join that network. Check the password, or pick another network.' ;;
  esac
}

# A password goes into a mode-0600 NetworkManager keyfile, never into argv.
kibaos_wifi_connect() {
  local ssid=$1 psk=$2 auth=${3:-} hidden=${4:-false} uuid profile output index
  local LC_ALL=C
  KIBAOS_WIFI_ERROR=
  if ! kibaos_wifi_available; then
    KIBAOS_WIFI_ERROR='NetworkManager is not on this image'
    return 1
  fi
  if [[ -z $ssid || $ssid == *[[:cntrl:]]* ]]; then
    KIBAOS_WIFI_ERROR='Choose a network first.'
    return 1
  fi
  if (( ${#ssid} > 32 )); then
    KIBAOS_WIFI_ERROR='That network name is too long.'
    return 1
  fi
  if [[ $psk == *[[:cntrl:]]* ]]; then
    KIBAOS_WIFI_ERROR='That password contains a character Wi-Fi cannot use.'
    return 1
  fi
  if [[ $hidden != true && $hidden != false ]]; then
    KIBAOS_WIFI_ERROR='Hidden-network setting is invalid.'
    return 1
  fi
  if [[ -z $psk && -z $auth && $hidden == false ]] && kibaos_wifi_saved "$ssid"; then
    if output=$("$KIBAOS_WIFI_NMCLI" connection up id "$ssid" 2>&1); then
      return 0
    fi
    KIBAOS_WIFI_ERROR=$(kibaos_wifi_reason "$output" '')
    return 1
  fi
  if [[ -z $auth ]]; then
    for index in "${!KIBAOS_WIFI_SSIDS[@]}"; do
      if [[ ${KIBAOS_WIFI_SSIDS[index]} == "$ssid" ]]; then
        auth=${KIBAOS_WIFI_AUTH[index]:-}
        break
      fi
    done
  fi
  [[ -n $auth ]] || { if [[ -n $psk ]]; then auth=wpa-psk; else auth=open; fi; }
  case $auth in
    enterprise)
      KIBAOS_WIFI_ERROR='This network needs work or school account setup. Use another network or a cable.'
      return 1 ;;
    legacy)
      KIBAOS_WIFI_ERROR='This older Wi-Fi security type is not supported here. Use another network or a cable.'
      return 1 ;;
    unknown)
      KIBAOS_WIFI_ERROR='This network uses a security type the installer does not recognize.'
      return 1 ;;
    open|owe)
      if [[ -n $psk ]]; then
        KIBAOS_WIFI_ERROR='This network does not use a password.'
        return 1
      fi ;;
    wpa-psk|sae)
      if [[ -z $psk ]]; then
        KIBAOS_WIFI_ERROR='This network needs a password.'
        return 1
      fi ;;
    *)
      KIBAOS_WIFI_ERROR='This network uses a security type the installer does not recognize.'
      return 1 ;;
  esac
  if [[ $auth == wpa-psk ]]; then
    if (( ${#psk} < 8 )); then
      KIBAOS_WIFI_ERROR='A Wi-Fi password is at least 8 characters.'
      return 1
    fi
    if (( ${#psk} > 63 )) &&
       ! { (( ${#psk} == 64 )) && [[ $psk =~ ^[0-9a-fA-F]+$ ]]; }; then
      KIBAOS_WIFI_ERROR='A Wi-Fi password is at most 63 characters.'
      return 1
    fi
  fi
  if ! install -d -m 0700 -- "$KIBAOS_WIFI_PROFILE_DIR" 2>/dev/null; then
    KIBAOS_WIFI_ERROR='Cannot write a network profile on this system.'
    return 1
  fi
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf 'kibaos-%s' "$$")
  profile="$KIBAOS_WIFI_PROFILE_DIR/kibaos-${uuid}.nmconnection"
  if ! (
    umask 077
    {
      printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' "$ssid" "$uuid"
      printf '[wifi]\nmode=infrastructure\nssid=%s\n' "$ssid"
      [[ $hidden != true ]] || printf 'hidden=true\n'
      [[ $auth == open ]] || printf 'security=802-11-wireless-security\n'
      printf '\n'
      if [[ $auth != open ]]; then
        printf '[wifi-security]\nkey-mgmt=%s\n' "$auth"
        [[ $auth != wpa-psk && $auth != sae ]] || printf 'psk=%s\n' "$psk"
        printf '\n'
      fi
      printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } >"$profile"
  ); then
    rm -f -- "$profile"
    KIBAOS_WIFI_ERROR='Cannot write a network profile on this system.'
    return 1
  fi
  chmod 600 -- "$profile"
  if ! "$KIBAOS_WIFI_NMCLI" connection load "$profile" >/dev/null 2>&1; then
    rm -f -- "$profile"
    KIBAOS_WIFI_ERROR='Could not save that network profile.'
    return 1
  fi
  if ! output=$("$KIBAOS_WIFI_NMCLI" connection up uuid "$uuid" 2>&1); then
    "$KIBAOS_WIFI_NMCLI" connection delete uuid "$uuid" >/dev/null 2>&1 || true
    rm -f -- "$profile"
    KIBAOS_WIFI_ERROR=$(kibaos_wifi_reason "$output" "$psk")
    return 1
  fi
  return 0
}

kibaos_wifi_forget() {
  local ssid=$1
  KIBAOS_WIFI_ERROR=
  if ! kibaos_wifi_available; then
    KIBAOS_WIFI_ERROR='NetworkManager is not on this image'
    return 1
  fi
  if ! kibaos_wifi_saved "$ssid"; then
    KIBAOS_WIFI_ERROR='This network is not saved.'
    return 1
  fi
  if "$KIBAOS_WIFI_NMCLI" connection delete id "$ssid" >/dev/null 2>&1; then
    return 0
  fi
  KIBAOS_WIFI_ERROR='Could not forget that network.'
  return 1
}

kibaos_wifi_radio() {
  local want=$1
  KIBAOS_WIFI_ERROR=
  if ! kibaos_wifi_available; then
    KIBAOS_WIFI_ERROR='NetworkManager is not on this image'
    return 1
  fi
  case $want in
    on|off) ;;
    *) KIBAOS_WIFI_ERROR='The radio is either on or off.'; return 1 ;;
  esac
  if "$KIBAOS_WIFI_NMCLI" radio wifi "$want" >/dev/null 2>&1; then
    return 0
  fi
  KIBAOS_WIFI_ERROR="Could not turn the Wi-Fi radio $want."
  return 1
}

# Only profiles created by the installer are carried into the installed OS.
kibaos_wifi_copy_profiles() {
  local profile dest="$1/etc/NetworkManager/system-connections"
  for profile in "$KIBAOS_WIFI_PROFILE_DIR"/kibaos-*.nmconnection; do
    [[ -f $profile && ! -L $profile ]] || continue
    install -d -m 0700 -- "$dest"
    install -m 0600 -- "$profile" "$dest/${profile##*/}"
  done
}
