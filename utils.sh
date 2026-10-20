#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("custom" "direct" "apkpure" "uptodown" "archive" "apkmirror" "apkarchive")

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}

_clean_tmp() {
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*tmp_* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	trap - SIGTERM SIGINT EXIT
	kill -9 -- -$$ 2>/dev/null
	exit 1
}
java() {
	if [ "${JAVA_HOME_21_X64-}" ]; then
		env -i JAVA_HOME="$JAVA_HOME_21_X64" "$JAVA_HOME_21_X64"/bin/java --enable-native-access=ALL-UNNAMED "$@"
	else
		env -i java --enable-native-access=ALL-UNNAMED "$@"
	fi
}

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "Patches $patches_src $patches_ver" "CLI $cli_src $cli_ver"; do
		set -- $src_ver
		local tag=$1 src=$2 ver=${3-}

		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel="https://api.github.com/repos/${src}/releases" name_ver
		if [ "$ver" = "dev" ]; then
			local resp
			resp=$(gh_req "$rv_rel" -) || return 1
			ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi
		if [ "$ver" = "latest" ]; then
			rv_rel+="/latest"
			name_ver="*"
		else
			rv_rel+="/tags/${ver}"
			name_ver="$ver"
		fi

		local file
		if [ "$tag" = "CLI" ]; then
			file=$(find "$dir" -maxdepth 1 -name "*cli-${name_ver#v}*.jar" -o -name "*desktop-${name_ver#v}*.jar" -type f 2>/dev/null)
			local grab_cl="false"
		elif [ "$tag" = "Patches" ]; then
			file=$(find "$dir" -maxdepth 1 -name "*patches-${name_ver#v}.*" -type f 2>/dev/null)
			local grab_cl="true"
		else abort unreachable; fi

		local url tag_name matches
		if [ "$ver" = "latest" ]; then
			file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
		else
			file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1)
		fi
		if [ -z "$file" ]; then
			local resp asset name
			resp=$(gh_req "$rv_rel" -) || return 1
			tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
			matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp") || return 1
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(jq -r .url <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			if [ "$tag" = "Patches" ]; then
				local name_ext="${name##*.}"
				name="patches-${tag_name#v}.${name_ext}"
			fi

			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			echo "$tag: ${src}/${name}  " >>"${cl_dir}/changelog.md"
		else
			local grab_cl="false"
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f2- <<<"$name")
			tag_name=v${tag_name%.*}
		fi

		if [ "$tag" = "Patches" ]; then
			if [ "$grab_cl" = "true" ]; then echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"; fi
			if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = "true" ]; then
				local extensions_ext
				extensions_ext=$(unzip -l "${file}" "extensions/shared.*" | grep -o "shared\..*") extensions_ext="${extensions_ext#*.}"
				(
					mkdir -p "${file}-zip" || return 1
					unzip -qo "${file}" -d "${file}-zip" || return 1
					java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${file}-zip/extensions/shared.${extensions_ext}" "${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
					mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" "${file}-zip/extensions/shared.${extensions_ext}" || return 1
					rm "${file}" || return 1
					cd "${file}-zip" || abort
					zip -0rq "${CWD}/${file}" . || return 1
				) >&2
				rm -r "${file}-zip" || :
			fi
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local rv_rel="https://api.github.com/repos/${PATCHES_SRC}/releases"
			if [ "$PATCHES_VER" = "dev" ]; then
				last_patches=$(gh_req "$rv_rel" - | jq -e -r '.[0]') || continue
			elif [ "$PATCHES_VER" = "latest" ]; then
				last_patches=$(gh_req "$rv_rel/latest" -) || continue
			else
				last_patches=$(gh_req "$rv_rel/tags/${PATCHES_VER}" -) || continue
			fi
			tag_name=$(jq -e -r '.tag_name' <<<"$last_patches") || abort "config_update error: No tag name"
			if ! last_patches=$(jq -e -r '.assets[] | select(.name | (endswith("asc") or endswith("json")) | not) | .name' <<<"$last_patches"); then
				abort "config_update error: '$last_patches'"
			fi
			if [ "$last_patches" ]; then
				local name_ext="${last_patches##*.}"
				last_patches="patches-${tag_name#v}.${name_ext}"

				if ! OP=$(grep -m1 "^Patches: ${PATCHES_SRC}/${last_patches}" build.md); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 --fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -s -t- -k1,1Vr <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 is_experimental=$4
	# _exc_sel=$4 _exclusive=$5
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | awk 'NR > 1 {print $1}')
	if [ -z "$op" ]; then
		abort "No patches found for '$pkg_name' in patches '$patches_jar'"
	elif [ "$op" = "Any" ]; then
		return
	fi
	get_highest_ver <<<"$op" || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local cmd_base="java -jar '$cli_jar' list-versions"

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = "revanced" ]; then
		cmd_base+=" -b"
	elif [ "$is_experimental" = "true" ]; then
		cmd_base+=" -x"
	fi

	local cmd="${cmd_base} --patches='$patches_jar' -f '$pkg_name'"
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi

	cmd="${cmd_base} '$patches_jar' -f '$pkg_name'"
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi

	epr "Could not list versions ($pkg_name) $cli_jar: '$op'"
	return 1
}
patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local op
	if ! op=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b 2>&1); then
		local cmd="java -jar '$cli_jar' list-patches --patches '$patches_jar' -f '$pkg_name' --with-versions --with-packages"
		if [ "$is_experimental" = "true" ]; then cmd+=" -x"; fi
		if ! op=$(eval "$cmd" 2>&1); then
			epr "Could not get patches list ($pkg_name) $cli_jar: '$op'"
			return 1
		fi

	fi
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

# Resolve the main APK member across APKM/XAPK/APKS archive naming schemes.
# Do not assume the main package is always literally named base.apk.
find_bundle_base_entry() {
	local bundle=$1 entries entry
	[ -s "$bundle" ] || return 1
	entries=$(unzip -Z1 "$bundle" 2>/dev/null) || return 1
	# Canonical split APK layout, including nested archive directories.
	entry=$(awk 'tolower($0) ~ /(^|\/)base\.apk$/ { print; exit }' <<<"$entries")
	if [ -n "$entry" ]; then printf '%s\n' "$entry"; return 0; fi
	# APKPure XAPK commonly names the base after the package ID.
	entry=$(awk 'tolower($0) ~ /(^|\/)com\.google\.android\.youtube\.apk$/ { print; exit }' <<<"$entries")
	if [ -n "$entry" ]; then printf '%s\n' "$entry"; return 0; fi
	# Other bundle exporters use base-master.apk or base_<variant>.apk.
	entry=$(awk 'tolower($0) ~ /(^|\/)base[-_][^/]*\.apk$/ && tolower($0) !~ /(config|split|feature|standalone)/ { print; exit }' <<<"$entries")
	if [ -n "$entry" ]; then printf '%s\n' "$entry"; return 0; fi
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	pr "Merging splits"
	if [ ! -f "$TEMP_DIR/apkeditor.jar" ]; then
		local resp dlurl
		resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || return 1
		dlurl=$(jq -e -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' <<<"$resp") || return 1
		gh_dl "$TEMP_DIR/apkeditor.jar" "$dlurl" >/dev/null || return 1
	fi
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		return 1
	fi
	# sign the merged stock apk
	if ! OP=$(java -jar "$APKSIGNER" sign --ks ks-p12.keystore --ks-pass pass:123456789 --key-pass pass:123456789 --ks-key-alias jhc \
		--out "${output}" "${output}-unsigned"); then
		epr "apksigner error: $OP"
		return 1
	fi
	rm "${output}.idsig" "${output}-unsigned" 2>/dev/null || :
	# Keep the original bundle until the caller validates its embedded
	# base.apk against the official package signing certificate. The merged
	# output is signed with our temporary build key, so checking its signer
	# would incorrectly report a signature mismatch against Google's cert.
	if [ ! -s "$output" ]; then
		epr "APKEditor reported success but produced no merged APK: $output"
		return 1
	fi
	return 0
}

# -------------------- apkmirror --------------------
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local dlurl="" node app_table emptyCheck

	local apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	if [ "$arch" != "all" ]; then
		apparch+=("$arch")
	fi

	local appdpi=("nodpi" "anydpi")
	if [ "$dpi" ]; then
		appdpi+=($dpi)
	fi

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" != "$apk_bundle" ]; then continue; fi
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if isoneof "$(sed -n 6p <<<"$app_table")" "${appdpi[@]}" &&
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ "$dlurl" ]; then
		# only one apk exists, return it
		echo "$dlurl"
		return 0
	fi
	return 1
}
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "${output}"
		return 0
	fi

	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	local resp node app_table apkmname dlurl=""
	apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
	apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
	url="${url}/${apkmname}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type"); then
				if [ "$type" = "BUNDLE" ]; then
					is_bundle=true
				else is_bundle=false; fi
				break 2
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		resp=$(req "$dlurl" -)
	fi
	url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	if [ "$is_bundle" = true ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$url" "${output}" || return 1
	fi
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')

	vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
	local v r_vers=()
	local IFS=$'\n'
	for v in $vers; do
		grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
	done
	echo "${r_vers[*]}"
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	__APKMIRROR_RESP__=$(req "${1}" -) || return 1
	__APKMIRROR_CAT__="${1##*/}"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_RESP__=$(req "${1}/versions" -) || return 1
	__UPTODOWN_RESP_PKG__=$(req "${1}/download" -) || return 1
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	[ "$arch" = "arm-v7a" ] && arch="armeabi-v7a"

	local op resp data_code version_url="" is_bundle=false
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	[ -n "$data_code" ] || data_code=$($HTMLQ "#detail-app-name" --attribute code <<<"$__UPTODOWN_RESP__")
	[ -n "$data_code" ] || { epr "Uptodown: app code missing"; return 1; }

	# Resolve the exact version. Uptodown's version API returns an object with
	# a versionURL object; don't manufacture a /post-download URL from it.
	for i in {1..20}; do
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -) || continue
		if ! op=$(jq -e -r --arg version "$version" '.data | map(select(.version == $version)) | .[0] // empty' <<<"$resp") || [ -z "$op" ]; then
			continue
		fi
		[ "$(jq -r '.kindFile // empty' <<<"$op")" = "xapk" ] && is_bundle=true
		version_url=$(jq -e -r '.versionURL.url + "/" + .versionURL.extraURL + "/" + (.versionURL.versionID | tostring)' <<<"$op") || return 1
		[ -n "$version_url" ] && break
	done
	[ -n "$version_url" ] || { epr "Uptodown: version $version not found in API"; return 1; }

	resp=$(req "$version_url" -) || return 1

	# Uptodown's generic "all" architecture path uses the download button on
	# the version page. Only query the variant endpoint for a concrete arch.
	if [ "$arch" != "all" ]; then
		local app_code data_version files node_arch data_file_id node_class file_type n
		app_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$resp")
		[ -n "$app_code" ] || app_code=$data_code
		data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
		[ -n "$data_version" ] || { epr "Uptodown: no variant list for version $version and arch $arch"; return 1; }
		files=$(req "${uptodown_dlurl%/*}/app/${app_code}/version/${data_version}/files" - | jq -e -r '.content // empty') || return 1
		[ -n "$files" ] || { epr "Uptodown: variant endpoint returned no content"; return 1; }
		for ((n=1; n<40; n++)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			# Uptodown labels ABI variants inconsistently across releases. Accept
			# exact ARM64 labels and combined ARM64/universal variants, but never
			# choose an ARMv7-only or x86-only APK for an ARM64 build.
			local normalized_arch=${node_arch,,}
			case "$arch" in
				arm64-v8a|arm64)
					[[ "$normalized_arch" == *arm64* || "$normalized_arch" == *universal* || "$normalized_arch" == *noarch* || "$normalized_arch" == *" all"* || "$normalized_arch" == "all" ]] || continue
					;;
				armeabi-v7a|arm-v7a)
					[[ "$normalized_arch" == *armeabi-v7a* || "$normalized_arch" == *armv7* || "$normalized_arch" == *universal* || "$normalized_arch" == *noarch* ]] || continue
					;;
				*) [[ "$normalized_arch" == *"$arch"* || "$normalized_arch" == *universal* || "$normalized_arch" == *noarch* ]] || continue ;;
			esac
			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			[ "$file_type" = "xapk" ] && is_bundle=true || is_bundle=false
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			[ -n "$data_file_id" ] || continue
			resp=$(req "${uptodown_dlurl}/download/${data_file_id}-x" -) || return 1
			break
		done
		[ "$n" -lt 40 ] || { epr "Uptodown: no compatible APK variant found for arch '$arch'"; return 1; }
	fi

	local data_url download_url candidate fallback_resp
	# Uptodown's markup changes often. Extract only from the actual download
	# button first; never accept an unrelated page-wide data-url (it can be
	# the literal word "apps", which produces the known /dwn/apps HTTP 400).
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp" 2>/dev/null || :)
	if [ -z "$data_url" ]; then
		data_url=$($HTMLQ ".button.download" --attribute data-url <<<"$resp" 2>/dev/null || :)
	fi
	if [ -z "$data_url" ]; then
		candidate=$($HTMLQ "#detail-download-button" --attribute href <<<"$resp" 2>/dev/null || :)
		case "$candidate" in
			https://*|http://*) data_url=$candidate ;;
			/dwn/*) data_url="https://dw.uptodown.com$candidate" ;;
			/download/*) data_url="https://dw.uptodown.com$candidate" ;;
			esac
	fi
	# Some Uptodown API payloads contain a usable download URL even when the
	# HTML button no longer exposes one. Restrict this to URL-like fields.
	if [ -z "$data_url" ]; then
		data_url=$(jq -r '.. | strings | select(test("^https?://[^ ]*(uptodown|dw\.uptodown)[^ ]*(/dwn/|/download/)"; "i"))' <<<"$op" 2>/dev/null | head -1)
	fi
	# Retry the app's generic download page if the version page token is absent
	# or is only a generic route name rather than a real token/path.
	if [ -z "$data_url" ] || [ "$data_url" = "apps" ] || [ "$data_url" = "/apps" ]; then
		fallback_resp=$(req "${uptodown_dlurl}/download" -) || fallback_resp=""
		data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$fallback_resp" 2>/dev/null || :)
		if [ -z "$data_url" ] || [ "$data_url" = "apps" ] || [ "$data_url" = "/apps" ]; then
			data_url=$($HTMLQ ".button.download" --attribute data-url <<<"$fallback_resp" 2>/dev/null || :)
		fi
		if [ -z "$data_url" ]; then
			candidate=$($HTMLQ "#detail-download-button" --attribute href <<<"$fallback_resp" 2>/dev/null || :)
			case "$candidate" in
				https://*|http://*) data_url=$candidate ;;
				/dwn/*) data_url="https://dw.uptodown.com$candidate" ;;
			esac
		fi
	fi
	[ -n "$data_url" ] || { epr "Uptodown: download URL/token absent from version and download pages"; return 1; }
	if [[ "$data_url" == http://* || "$data_url" == https://* ]]; then
		download_url=$data_url
	else
		# Real Uptodown tokens are multi-part paths. Reject generic route names
		# instead of issuing a guaranteed-bad request to /dwn/apps.
		case "$data_url" in
			*/*) download_url="https://dw.uptodown.com/dwn/${data_url#/}" ;;
			*) epr "Uptodown: invalid download token '$data_url' (not a token path)"; return 1 ;;
		esac
	fi

	if [ "$is_bundle" = true ]; then
		req "$download_url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "$download_url" "$output"
	fi
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

# -------------------- apkarchive --------------------
# Additional public mirror fallback. Keep parsing conservative: only follow a
# page/link that explicitly contains the requested version, and only download
# URLs from the selected version page.
get_apkarchive_resp() {
	__APKARCHIVE_URL__="${1%/}"
	__APKARCHIVE_RESP__=$(req "$__APKARCHIVE_URL__" -) || return 1
}
get_apkarchive_pkg_name() { echo "com.google.android.youtube"; }
get_apkarchive_vers() {
	grep -oE '([0-9]+\.){2}[0-9]+' <<<"$__APKARCHIVE_RESP__" | awk '!seen[$0]++'
}
dl_apkarchive() {
	local base=${1%/} version=$2 output=$3 arch=$4 _dpi=$5
	local href detail page url
	# Find a version-specific detail page; avoid selecting generic site links.
	href=$(grep -oE 'href="[^"]+"' <<<"$__APKARCHIVE_RESP__" | sed -E 's/^href="//;s/"$//' | grep -F "$version" | grep -E '^https?://|^/' | head -1)
	[ -n "$href" ] || { epr "APKArchive: no detail page found for version $version"; return 1; }
	if [[ "$href" == http://* || "$href" == https://* ]]; then detail=$href; else detail="https://apkarchive.org${href}"; fi
	page=$(req "$detail" -) || return 1
	# Prefer explicit APK download links. If the site uses an intermediate
	# download page, follow it once and extract the final APK URL there.
	url=$(grep -oE 'https?://[^"'"'"' <>]+\.(apk|apkm)(\?[^"'"'"' <>]*)?' <<<"$page" | head -1)
	if [ -z "$url" ]; then
		href=$(grep -oE 'href="[^"]+"' <<<"$page" | sed -E 's/^href="//;s/"$//' | grep -Ei 'download|/get/' | head -1)
		if [ -n "$href" ]; then
			if [[ "$href" == http://* || "$href" == https://* ]]; then detail=$href; else detail="https://apkarchive.org${href}"; fi
			page=$(req "$detail" -) || return 1
			url=$(grep -oE 'https?://[^"'"'"' <>]+\.(apk|apkm)(\?[^"'"'"' <>]*)?' <<<"$page" | head -1)
		fi
	fi
	[ -n "$url" ] || { epr "APKArchive: no direct APK link found for version $version"; return 1; }
	if [[ "$url" == *.apkm* ]]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "$url" "$output"
	fi
}

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version=${version// /}

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "$output"
		return 0
	fi

	# Prefer the requested ABI. For arch=all, older archive mirrors often
	# store only the universal APK or an arm64 APK; accept arm64 as a practical
	# fallback for modern Android devices instead of failing on the suffix.
	if ! path=$(grep -m1 -E "${version_f#v}-${arch// /}\.(apk|apkm)([?<]|$)" <<<"$__ARCHIVE_RESP__"); then
		path=$(grep -m1 -E "${version_f#v}-all\.(apk|apkm)([?<]|$)" <<<"$__ARCHIVE_RESP__") || :
	fi
	if [ -z "$path" ] && [ "$arch" = "all" ]; then
		path=$(grep -m1 -E "${version_f#v}-arm64-v8a\.(apk|apkm)([?<]|$)" <<<"$__ARCHIVE_RESP__") || :
	fi
	[ -n "$path" ] || return 1
	path=${path%%\?*}

	if [ "${path##*.}" = "apkm" ]; then
		req "${url}/${path}" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "${url}/${path}" "${output}" || return 1
	fi
}
get_archive_resp() {
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\)\.\(apk\|apkm\)//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- apkpure --------------------
# APKPure is a fallback source when Uptodown's token endpoint or APKMirror
# blocks automated runners. Its version page exposes exact version links and
# the download page links to d.apkpure.net bundle downloads.
get_apkpure_resp() {
	__APKPURE_URL__="${1%/}"
	# The HTML versions page is often HTTP 403 in CI. Do not make it a
	# prerequisite: the direct d.apkpure.net endpoint can serve a pinned
	# version by versionCode without scraping that page.
	__APKPURE_RESP__=$(req "${__APKPURE_URL__}/versions" - 2>/dev/null) || __APKPURE_RESP__=""
	return 0
}
get_apkpure_vers() {
	grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$__APKPURE_RESP__" | awk '!seen[$0]++'
}
get_apkpure_pkg_name() { echo "${__APKPURE_URL__##*/}"; }
dl_apkpure() {
	local base=${1%/} version=$2 output=$3 arch=$4 _dpi=$5
	local page url version_code="" sig_output=""
	# Version codes are pinned explicitly; never let a fallback silently change version.
	case "$version" in
		21.41.530) version_code="1561303465" ;;
		21.39.525) version_code="1561299928" ;;
		21.39.524) version_code="1561299919" ;;
		21.40.161) version_code="1561301411" ;;
		21.40.162) version_code="1561301422" ;;
	esac
	if [ -n "$version_code" ]; then
		# Prefer a version-pinned XAPK bundle so the module can package the
		# original stock base and configuration splits, not only a single base APK.
		# The common download loop validates the embedded base APK against Google's
		# official signer before accepting the bundle.
		for url in \
			"https://d.apkpure.net/b/XAPK/com.google.android.youtube?versionCode=${version_code}" \
			"https://d.apkpure.net/b/XAPK/com.google.android.youtube?version=${version}"; do
			pr "APKPure: trying version-pinned XAPK bundle for $version"
			if req "$url" "${output}.apkm" && merge_splits "${output}.apkm" "$output"; then return 0; fi
			rm -f "${output}.apkm" "${output}.base.apk" "$output" "${output}-unsigned"
		done

		# Only use a standalone APK if the split bundle endpoints are unavailable.
		# The packaging step will reject this fallback when include-stock=split is
		# requested, instead of silently releasing an undersized/incomplete module.
		pr "APKPure: trying standalone APK endpoint for version $version"
		url="https://d.apkpure.net/b/APK/com.google.android.youtube?versionCode=${version_code}"
		if req "$url" "$output"; then
			if sig_output=$(check_sig "$output" "com.google.android.youtube" 2>&1); then
				pr "APKPure: standalone APK signature verified"
				return 0
			fi
			epr "APKPure: standalone APK rejected by signature check: $sig_output"
			rm -f "$output"
		fi
	else
		epr "APKPure: no verified direct versionCode mapping for pinned version $version"
	fi
	# Fallback to the version page when direct endpoints fail.
	page=$(req "${base}/download/${version}" -) || return 1
	url=$(printf '%s' "$page" | $HTMLQ --base https://apkpure.net --attribute href 'a[href*="d.apkpure.net"]' 2>/dev/null | head -1)
	if [ -z "$url" ]; then
		url=$(grep -oE 'https?[^"'"'"' ]*d\.apkpure\.net[^"'"'"' ]*' <<<"$page" | head -1 | sed 's/&amp;/\&/g')
	fi
	[ -n "$url" ] || { epr "APKPure: no direct download link found for version $version"; return 1; }
	req "$url" "${output}.apkm" || return 1
	merge_splits "${output}.apkm" "$output"
}
# --------------------------------------------------

# -------------------- custom user-supplied stock APK/bundle --------------------
# A workflow_dispatch URL lets maintainers supply the original Google-signed
# stable 21.41.530 APK/XAPK/APKM/APKS when public mirrors block GitHub-hosted runners.
# The normal downstream package/signature validation remains mandatory.
get_custom_resp() {
    [ -n "${YOUTUBE_STOCK_APK_URL-}" ]
}
get_custom_vers() { echo "21.41.530"; }
get_custom_pkg_name() { echo "com.google.android.youtube"; }
dl_custom() {
    local _source=$1 version=$2 output=$3 _arch=$4 _dpi=$5
    local tmp="${output}.custom-download" base_entry
    [ -n "${YOUTUBE_STOCK_APK_URL-}" ] || return 1
    case "$version" in 21.41.530) ;; *) epr "Custom stock URL is only enabled for pinned stable YouTube 21.41.530"; return 1 ;; esac
    rm -f "$tmp" "${output}.apkm" "${output}.base.apk" "$output" "${output}-unsigned"
    pr "Downloading pinned YouTube $version from supplied stock APK URL"
    if ! req "$YOUTUBE_STOCK_APK_URL" "$tmp"; then rm -f "$tmp"; return 1; fi
    if ! unzip -tq "$tmp" >/dev/null 2>&1; then
        epr "Custom stock URL did not return a valid APK or ZIP bundle"
        rm -f "$tmp"
        return 1
    fi
    base_entry=$(find_bundle_base_entry "$tmp" || :)
    if [ -n "$base_entry" ]; then
        mv -f "$tmp" "${output}.apkm"
        # Produce the merged APK for patching, while retaining the original
        # bundle so downstream checks can verify Google's original base signer.
        if ! merge_splits "${output}.apkm" "$output"; then
            rm -f "${output}.apkm" "${output}.base.apk" "$output" "${output}-unsigned"
            return 1
        fi
    else
        # Standalone APK: signature and package are checked by the common path.
        mv -f "$tmp" "$output"
    fi
    return 0
}
# -----------------------------------------------------------------------------

# -------------------- direct --------------------
dl_direct() {
	local url=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	if ! grep -q "${version_f#v}-${arch// /}" <<<"$url"; then
		epr "Given direct-dlurl for $output is not compatible. Set proper 'arch' and 'version' options."
		return 1
	fi
	if [ "${url##*.}" = "apkm" ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "$url" "${output}" || return 1
	fi
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__"; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__"; }
get_direct_resp() { __DIRECT_APKNAME__=$(awk -F/ '{print $NF}' <<<"$1"); }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local tmp_files
	tmp_files="$(pwd)/$(mktemp -d -p "$TEMP_DIR")"

	local cmd="java -jar '$cli_jar' patch '$stock_input' -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc -t '$tmp_files' $patcher_args"

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = "revanced" ]; then
		cmd+=" -b"
		if [ "$OS" = "Android" ]; then cmd+=" --custom-aapt2-binary='${AAPT2}'"; fi
	fi

	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	if [ "${args[pkg_name]}" ]; then
		pkg_name="${args[pkg_name]}"
	else
		for dl_p in "${DL_SRCS[@]}"; do
			if [ "$dl_p" = custom ]; then
				[ -n "${YOUTUBE_STOCK_APK_URL-}" ] || continue
			else
				if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			fi
			if ! get_"${dl_p}"_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				epr "ERROR: Could not find ${table} in ${dl_p}"
				continue
			fi
			tried_dl+=("$dl_p")
			dl_from=$dl_p
			break
		done
	fi

	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	pr "Package name of '${table}' is '$pkg_name'"
	local list_patches

	local is_experimental="false"
	if [ "$version_mode" = "experimental" ]; then is_experimental="true"; fi
	list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental") || return 1
	local get_latest_ver=false
	if isoneof "$version_mode" "auto" "experimental"; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" "${args[included_patches]}" "$is_experimental"); then
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return
		elif [ -z "$version" ]; then get_latest_ver="true"; fi
	elif [ "$version_mode" = "latest" ]; then
		get_latest_ver="true"
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = "true" ]; then
		if ! isoneof "$dl_from" "${tried_dl[@]}"; then
			if ! get_"${dl_from}"_resp "${args[${dl_from}_dlurl]}"; then
				abort "ERROR: Could not get '${table}' from '${dl_from}'"
			fi
		fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi

	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"

	# If the newest patch-compatible version is missing from every configured
	# mirror, try older versions that the same patch set explicitly supports.
	# This is limited to auto/experimental selection; a manually pinned version
	# is never silently changed. Included-patch builds are also left untouched
	# because their compatibility intersection can be narrower.
	local candidate_versions=("$version") candidate_seen=$'\n'"${version}"$'\n' compat_versions candidate
	if isoneof "$version_mode" "auto" "experimental" && [ -z "${args[included_patches]}" ] && [ "$get_latest_ver" != "true" ]; then
		if compat_versions=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental" 2>/dev/null); then
			while IFS= read -r candidate; do
				candidate=${candidate%%[[:space:]]*}
				[ -n "$candidate" ] || continue
				[[ "$candidate" =~ ^v?[0-9]+(\.[0-9]+){1,3}([.-][[:alnum:]._+-]+)?$ ]] || continue
				case "$candidate_seen" in *$'\n'"$candidate"$'\n'*) continue ;; esac
				candidate_versions+=("$candidate")
				candidate_seen+="$candidate"$'\n'
			done < <(sed -n '/Most common compatible versions:/,$p' <<<"$compat_versions" | tail -n +2)
		fi
	fi

	local download_ok=false candidate_index=0
	for candidate in "${candidate_versions[@]}"; do
		candidate_index=$((candidate_index + 1))
		version="$candidate"
		version_f=${version// /}
		version_f=${version_f#v}
		stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
		if [ -f "$stock_apk" ]; then download_ok=true; break; fi
		if [ "$candidate_index" -gt 1 ]; then
			wpr "Selected version unavailable; trying older patch-compatible YouTube version '$version'"
		fi
		for dl_p in "${DL_SRCS[@]}"; do
			if [ "$dl_p" = custom ]; then
				[ -n "${YOUTUBE_STOCK_APK_URL-}" ] || continue
			else
				if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			fi
			pr "Downloading '${table}' from '${dl_p}' (version ${version})"
			if ! isoneof "$dl_p" "${tried_dl[@]}"; then
				if ! get_"${dl_p}"_resp "${args[${dl_p}_dlurl]}"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_"${dl_p}" "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi

			# Reject untrusted/repacked downloads and continue to the next source.
			# For bundles, validate the untouched base APK preserved by merge_splits.
			local candidate_sig_file="$stock_apk" candidate_sig_tmp=""
			if [ -s "${stock_apk}.base.apk" ]; then
				candidate_sig_file="${stock_apk}.base.apk"
			elif [ -f "${stock_apk}.apkm" ]; then
				local candidate_entry
				candidate_entry=$(find_bundle_base_entry "${stock_apk}.apkm" || :)
				candidate_sig_tmp="${stock_apk}.source-base-check.apk"
				if [ -n "$candidate_entry" ] && unzip -p "${stock_apk}.apkm" "$candidate_entry" > "$candidate_sig_tmp" && [ -s "$candidate_sig_tmp" ]; then
					candidate_sig_file="$candidate_sig_tmp"
				else
					epr "Rejecting '${dl_p}': could not extract original base APK for signature validation"
					rm -f "$candidate_sig_tmp" "${stock_apk}.apkm" "${stock_apk}.base.apk" "$stock_apk" "${stock_apk}-unsigned"
					continue
				fi
			fi
			if ! sig_op=$(check_sig "$candidate_sig_file" "$pkg_name" 2>&1); then
				epr "Rejecting '${dl_p}' download: official signature check failed: $sig_op"
				rm -f "$candidate_sig_tmp" "${stock_apk}.apkm" "${stock_apk}.base.apk" "$stock_apk" "${stock_apk}-unsigned"
				continue
			fi
			rm -f "$candidate_sig_tmp"
			if [ -f "$stock_apk" ] || [ -f "${stock_apk}.apkm" ]; then
				download_ok=true
				break
			fi
		done
		[ "$download_ok" = true ] && break
	done
	if [ "$download_ok" != true ] || [ ! -f "$stock_apk" ]; then
		epr "Stock apk not found for selected or older compatible versions (last tried: ${stock_apk})"
		return 0
	fi

	local sig_op
	if [ -f "${stock_apk}.apkm" ]; then
		# Do not assume the bundle stores base.apk at its ZIP root or trust a
		# stale merged APK. Locate the actual base entry, extract it without
		# flattening the archive, then verify Google's original signing cert.
		local base_entry base_check
		base_entry=$(find_bundle_base_entry "${stock_apk}.apkm" || :)
		if [ -z "$base_entry" ]; then
			epr "Rejecting ${table}: downloaded bundle has no base.apk entry; archive may be incomplete or not a split-APK bundle."
			return 0
		fi
		base_check="${stock_apk}.source-base-check.apk"
		if ! unzip -p "${stock_apk}.apkm" "$base_entry" > "$base_check" || [ ! -s "$base_check" ]; then
			rm -f "$base_check"
			epr "Rejecting ${table}: could not extract base APK from bundle entry '$base_entry'."
			return 0
		fi
		if ! sig_op=$(check_sig "$base_check" "$pkg_name" 2>&1); then
			rm -f "$base_check"
			epr "Not building $table: original base APK signature verification failed for '$base_entry': $sig_op"
			return 0
		fi
		rm -f "$base_check"
		# Keep the original bundle for stock split packaging; the merged APK is
		# signed with the temporary build key and is not Google's original APK.
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi
	log "${table}: ${version}"
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi

	local branding_patch
	branding_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "custom branding" || :) branding_patch=${branding_patch#*: }
	if [[ ${p_patcher_args[*]} =~ $branding_patch ]]; then
		branding_patch=""
	fi

	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		wpr "Cannot include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi

		if [ "$build_mode" = "apk" ]; then
			if [ -n "$microg_patch" ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			fi
		elif [ "$build_mode" = "module" ]; then
			if [ -n "$microg_patch" ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
			if [ -n "$branding_patch" ]; then
				patcher_args+=("-d \"${branding_patch}\"")
			fi
		else
			abort unreachable
		fi

		if [ "${args[enable_update_checks]}" = "true" ] && [ "$build_mode" = "apk" ] && [ -n "${GITHUB_REPOSITORY-}" ]; then
			local p="$TEMP_DIR/jhc-update-check.mpp"
			if [ ! -f $p ]; then
				local resp dlurl
				resp=$(gh_req "https://api.github.com/repos/j-hc/morphe-jhc-update-check-patch/releases/latest" -) || return 1
				dlurl=$(jq -e -r '.assets[0] | .browser_download_url' <<<"$resp") || return 1
				gh_dl $p "$dlurl" >/dev/null || return 1
			fi
			patcher_args+=("-p '$p'")

			local v
			v=$(git tag --sort=committerdate | tail -1) || :
			if [[ $v =~ ^[0-9]+$ ]]; then
				v=$((v + 1))
				patcher_args+=("-e 'j-hc Update Check Res' -OcurrentTag='\"$v\"' -OupdateRepo='\"${GITHUB_REPOSITORY}\"'")
			else
				epr "'$v' is not a proper version tag"
			fi
		fi

		local stock_apk_to_patch="${stock_apk}.stripped.apk"
		cp -f "$stock_apk" "$stock_apk_to_patch"
		if [ "$build_mode" = module ]; then
			zip -d "$stock_apk_to_patch" "lib/*" >/dev/null 2>&1 || :
		else
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
		fi

		local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		rm "$stock_apk_to_patch"
		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"

		local patches_ver="${patches_jar##*-}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[rv_brand]}" \
			"${version} (patches ${patches_ver})" \
			"${app_name} ${args[rv_brand]} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			if [ "${args[include_stock]}" = "merged" ]; then
				cp -f "$stock_apk" "${base_template}/stock/base.apk"
			elif [ "${args[include_stock]}" = "split" ]; then
				if [ ! -s "${stock_apk}.apkm" ]; then
					abort "Cannot build a complete module: include-stock=split was requested but no verified stock bundle exists for $table_name. Refusing to publish a base-APK-only module."
				fi
				# Extract APK members while preserving names, then normalize the
				# identified base entry to stock/base.apk. This avoids unzip -j
				# silently missing or overwriting entries in non-root bundle layouts.
				local stock_base_entry
				stock_base_entry=$(find_bundle_base_entry "${stock_apk}.apkm" || :)
				if [ -z "$stock_base_entry" ]; then
					abort "Cannot package complete module: stock bundle has no recognizable main APK entry for $table_name."
				fi
				local split_excludes=()
				if [ "$arch" = "arm64-v8a" ]; then
					split_excludes=('*x86_64.apk' '*x86.apk' '*armeabi_v7a.apk' '*armeabi-v7a.apk')
				elif [ "$arch" = "arm-v7a" ]; then
					split_excludes=('*x86_64.apk' '*x86.apk' '*arm64_v8a.apk' '*arm64-v8a.apk')
				elif [ "$arch" = "x86" ]; then
					split_excludes=('*x86_64.apk' '*arm64_v8a.apk' '*arm64-v8a.apk' '*armeabi_v7a.apk' '*armeabi-v7a.apk')
				elif [ "$arch" = "x86_64" ]; then
					split_excludes=('*x86.apk' '*arm64_v8a.apk' '*arm64-v8a.apk' '*armeabi_v7a.apk' '*armeabi-v7a.apk')
				else
					split_excludes=('*x86_64.apk' '*x86.apk')
				fi
				# Extract the main APK directly to the canonical name, even if the
				# source bundle calls it com.google.android.youtube.apk or nests it.
				if ! unzip -p "${stock_apk}.apkm" "$stock_base_entry" > "${base_template}/stock/base.apk" || [ ! -s "${base_template}/stock/base.apk" ]; then
					abort "Could not extract main stock APK '$stock_base_entry' for $table_name."
				fi
				mkdir -p "${base_template}/stock/.bundle-extract"
				if ! unzip -oq "${stock_apk}.apkm" '*.apk' -x "$stock_base_entry" "${split_excludes[@]}" -d "${base_template}/stock/.bundle-extract" >/dev/null 2>&1; then
					rm -rf "${base_template}/stock/.bundle-extract"
					abort "Failed extracting stock split APKs for $table_name."
				fi
				find "${base_template}/stock/.bundle-extract" -type f -name '*.apk' -exec cp -f '{}' "${base_template}/stock/" \;
				rm -rf "${base_template}/stock/.bundle-extract"
				local stock_split_count
				stock_split_count=$(find "${base_template}/stock" -maxdepth 1 -type f -name '*.apk' | wc -l)
				if [ ! -s "${base_template}/stock/base.apk" ] || [ "$stock_split_count" -lt 2 ]; then
					abort "Incomplete stock split set for $table_name: expected base.apk plus at least one split APK; refusing to publish an incomplete module."
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
