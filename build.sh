name: "Build KibaOS"
# One pipeline per architecture:
#   build_<arch> -> latest_<arch> -> publish_<arch> and ota_<arch>
# Each architecture builds, publishes and OTAs on its own, so one failing never
# blocks another. To add an architecture, copy the four *_x86_64 jobs and change
# the arch, runner, docker image and SourceForge paths.
on:
  workflow_dispatch:
    inputs:
      skip_build:
        description: 'Skip building; publish + OTA the newest GitHub build artifact if SourceForge is older'
        required: false
        type: boolean
        default: false
      skip_ota:
        description: 'Skip OTA generation and publishing'
        required: false
        type: boolean
        default: false
      run_vmtest:
        description: 'Run UEFI VM test using the newest available GitHub build artifact'
        required: false
        type: boolean
        default: false
jobs:
  build_x86_64:
    if: ${{ !inputs.skip_build }}
    runs-on: ubuntu-latest
    timeout-minutes: 180
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Free disk space
        uses: endersonmenezes/free-disk-space@v3
        with:
          remove_android: true
          remove_dotnet: true
          remove_haskell: true
          remove_tool_cache: true
          remove_swap: true
          remove_packages: "azure-cli google-cloud-cli microsoft-edge-stable google-chrome-stable firefox postgresql* temurin-* *llvm* mysql* dotnet-sdk-*"
          remove_packages_one_command: true
          remove_folders: "/usr/share/swift /usr/share/miniconda /usr/share/az* /usr/local/lib/node_modules /usr/local/share/chromium /usr/local/share/powershell"
          rm_cmd: "rmz"
          rmz_version: "3.1.1"
      - name: Run build in Docker
        run: |
          docker run --rm --privileged \
            -v "$PWD:/w" \
            -e RUN_NUM="${{ github.run_number }}" \
            -e KIBA_ARCH="x86_64" \
            "archlinux:latest" \
            /bin/bash /w/build.sh
      - name: Upload build artifact
        uses: actions/upload-artifact@v4
        with:
          name: kibaos-build-x86_64
          path: |
            *.iso
            *.iso.sha256
          retention-days: 7
  # Decides which GitHub artifact to ship and whether SourceForge needs it.
  #  - Build ran this run: ship this run's artifact (always newer than SourceForge).
  #  - Build skipped: find the newest unexpired artifact from an earlier run and
  #    only ship it if SourceForge's recorded version is older than that run.
  latest_x86_64:
    needs: build_x86_64
    if: ${{ !cancelled() && contains(fromJSON('["success","skipped"]'), needs.build_x86_64.result) }}
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      actions: read
    outputs:
      run_id: ${{ steps.pick.outputs.run_id }}
      patch_num: ${{ steps.pick.outputs.patch_num }}
      head_sha: ${{ steps.pick.outputs.head_sha }}
      publish_needed: ${{ steps.compare.outputs.publish_needed }}
      ota_needed: ${{ steps.compare.outputs.ota_needed }}
    steps:
      - name: Pick the newest x86_64 build artifact
        id: pick
        uses: actions/github-script@v7
        env:
          BUILD_RESULT: ${{ needs.build_x86_64.result }}
        with:
          script: |
            const owner = context.repo.owner;
            const repo = context.repo.repo;
            const artifactName = 'kibaos-build-x86_64';

            if (process.env.BUILD_RESULT === 'success') {
              core.info(`Build ran in this run; using run ${context.runId}.`);
              core.setOutput('run_id', String(context.runId));
              core.setOutput('patch_num', String(context.runNumber));
              core.setOutput('head_sha', context.sha);
              core.setOutput('fresh', 'true');
              return;
            }

            const workflowRef = process.env.GITHUB_WORKFLOW_REF;
            const workflowFile = workflowRef.split('/.github/workflows/')[1]?.split('@')[0];
            if (!workflowFile) {
              core.setFailed(`Could not determine workflow file from GITHUB_WORKFLOW_REF: ${workflowRef}`);
              return;
            }
            const branch = context.ref.startsWith('refs/heads/')
              ? context.ref.replace(/^refs\/heads\//, '')
              : undefined;

            core.info(`Build skipped; searching ${workflowFile} runs newest-first for ${artifactName}.`);
            for (let page = 1; ; page++) {
              const response = await github.rest.actions.listWorkflowRuns({
                owner,
                repo,
                workflow_id: workflowFile,
                ...(branch ? { branch } : {}),
                per_page: 100,
                page
              });
              const runs = response.data.workflow_runs;
              if (runs.length === 0) break;

              for (const run of runs) {
                if (run.id === context.runId) continue;
                const artifacts = await github.paginate(
                  github.rest.actions.listWorkflowRunArtifacts,
                  { owner, repo, run_id: run.id, per_page: 100 }
                );
                const match = artifacts.find(a => a.name === artifactName && !a.expired);
                if (match) {
                  core.info(`Found ${artifactName} in run ${run.id} (#${run.run_number}, ${run.html_url}).`);
                  core.setOutput('run_id', String(run.id));
                  core.setOutput('patch_num', String(run.run_number));
                  core.setOutput('head_sha', run.head_sha);
                  core.setOutput('fresh', 'false');
                  return;
                }
                core.info(`Run ${run.id} has no usable ${artifactName}; checking the next older run.`);
              }
            }
            core.setFailed(`No unexpired ${artifactName} artifact found in any previous run of ${workflowFile}${branch ? ` on branch ${branch}` : ''}.`);
      - name: Compare with the latest version on SourceForge
        id: compare
        env:
          SF_USER: ${{ secrets.SF_USER }}
          SSHPASS: ${{ secrets.SF_PASS }}
          ART: ${{ steps.pick.outputs.patch_num }}
          FRESH: ${{ steps.pick.outputs.fresh }}
        run: |
          if [ -z "$SF_USER" ] || [ -z "$SSHPASS" ]; then
            echo "SourceForge credentials not configured. Nothing to push."
            echo "publish_needed=false" >> "$GITHUB_OUTPUT"
            echo "ota_needed=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          if [ "$FRESH" = "true" ]; then
            echo "Fresh build #${ART} -- publishing and generating OTA."
            echo "publish_needed=true" >> "$GITHUB_OUTPUT"
            echo "ota_needed=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          sudo apt-get install -y sshpass rsync
          mkdir -p ~/.ssh
          ssh-keyscan -H frs.sourceforge.net >> ~/.ssh/known_hosts

          SF=/home/frs/project/kibaos
          # Prints the leading integer of a remote file, or 0 if missing/empty.
          read_version() {
            local f v
            f=$(mktemp)
            sshpass -e rsync -q "$SF_USER@frs.sourceforge.net:${SF}/$1" "$f" 2>/dev/null || true
            v=$(grep -Eo '^[0-9]+' "$f" | head -1 || true)
            echo "${v:-0}"
          }

          SF_ISO=$(read_version x86_64/last-iso-build-number-x86_64.txt)
          SF_OTA=$(read_version ota/last-ota-build-x86_64.txt)
          # Older SourceForge layouts only have latest-patch-level.
          [ "$SF_OTA" -eq 0 ] && SF_OTA=$(read_version ota/latest-patch-level)

          PUB=false; OTA=false
          [ "$SF_ISO" -lt "$ART" ] && PUB=true
          [ "$SF_OTA" -lt "$ART" ] && OTA=true
          echo "publish_needed=${PUB}" >> "$GITHUB_OUTPUT"
          echo "ota_needed=${OTA}" >> "$GITHUB_OUTPUT"
          {
            echo "### Skipped build: latest artifact vs SourceForge (x86_64)"
            echo "- Latest GitHub artifact: v${ART}"
            echo "- SourceForge ISO: v${SF_ISO} -> publish ${PUB}"
            echo "- SourceForge OTA: v${SF_OTA} -> OTA ${OTA}"
          } | tee -a "$GITHUB_STEP_SUMMARY"
  publish_x86_64:
    needs: latest_x86_64
    if: ${{ needs.latest_x86_64.outputs.publish_needed == 'true' }}
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      actions: read
    env:
      SF_USER: ${{ secrets.SF_USER }}
      SSHPASS: ${{ secrets.SF_PASS }}
      REMOTE_DIR: /home/frs/project/kibaos/x86_64
      MARKER: last-iso-build-number-x86_64.txt
      PATCH_NUM: ${{ needs.latest_x86_64.outputs.patch_num }}
    steps:
      - name: Download build artifact
        uses: actions/download-artifact@v4
        with:
          name: kibaos-build-x86_64
          run-id: ${{ needs.latest_x86_64.outputs.run_id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          path: dist
      - name: Prepare SSH
        run: |
          sudo apt-get install -y sshpass rsync
          mkdir -p ~/.ssh
          ssh-keyscan -H frs.sourceforge.net >> ~/.ssh/known_hosts
      - name: Remove previous build from SourceForge
        run: |
          rm -f "${MARKER}"
          sshpass -e rsync -avP "$SF_USER@frs.sourceforge.net:${REMOTE_DIR}/${MARKER}" "${MARKER}" 2>/dev/null || true
          if [ -s "${MARKER}" ]; then
            PREV_ISO="kibaos-v$(cat "${MARKER}").iso"
            echo "Removing previous x86_64 build: ${PREV_ISO} (+ .sha256)"
            printf '%s\n' "cd ${REMOTE_DIR}" "rm ${PREV_ISO}" "rm ${PREV_ISO}.sha256" "bye" \
              | sshpass -e sftp -oStrictHostKeyChecking=no -oBatchMode=no "$SF_USER@frs.sourceforge.net" 2>/dev/null || true
          else
            echo "No previous build marker for x86_64 -- nothing to delete."
          fi
      - name: Upload to SourceForge
        run: |
          FILES=()
          for pat in "*.iso" "*.iso.sha256"; do
            mapfile -t FOUND < <(find dist -type f -name "$pat")
            if [ "${#FOUND[@]}" -eq 0 ]; then
              echo "::error::No file matching ${pat} in the x86_64 build artifact" >&2
              exit 1
            fi
            FILES+=("${FOUND[@]}")
          done
          printf 'Uploading: %s\n' "${FILES[@]}"
          sshpass -e rsync -avP --progress "${FILES[@]}" "$SF_USER@frs.sourceforge.net:${REMOTE_DIR}/"
      - name: Record build marker on SourceForge
        run: |
          echo "${PATCH_NUM}" > "${MARKER}"
          sshpass -e rsync -avP "${MARKER}" "$SF_USER@frs.sourceforge.net:${REMOTE_DIR}/${MARKER}"
  vmtest_find:
    needs: build_x86_64
    if: ${{ always() && inputs.run_vmtest }}
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      actions: read
    outputs:
      run_id: ${{ steps.find-build-artifact.outputs.run_id }}
    steps:
      - name: Find newest run containing the x86_64 build artifact
        id: find-build-artifact
        uses: actions/github-script@v7
        with:
          script: |
            const owner = context.repo.owner;
            const repo = context.repo.repo;
            const artifactName = 'kibaos-build-x86_64';
            const workflowRef = process.env.GITHUB_WORKFLOW_REF;
            const workflowFile = workflowRef.split('/.github/workflows/')[1]?.split('@')[0];
            if (!workflowFile) {
              core.setFailed(`Could not determine workflow file from GITHUB_WORKFLOW_REF: ${workflowRef}`);
              return;
            }

            const branch = context.ref.startsWith('refs/heads/')
              ? context.ref.replace(/^refs\/heads\//, '')
              : undefined;

            const currentArtifacts = await github.paginate(
              github.rest.actions.listWorkflowRunArtifacts,
              { owner, repo, run_id: context.runId, per_page: 100 }
            );
            const currentArtifact = currentArtifacts.find(
              artifact => artifact.name === artifactName && !artifact.expired
            );
            if (currentArtifact) {
              core.info(`Using ${artifactName} from the current run ${context.runId}.`);
              core.setOutput('run_id', String(context.runId));
              core.setOutput('artifact_id', String(currentArtifact.id));
              return;
            }

            core.info(`No ${artifactName} in current run ${context.runId}; searching older runs newest-first.`);
            for (let page = 1; ; page++) {
              const response = await github.rest.actions.listWorkflowRuns({
                owner,
                repo,
                workflow_id: workflowFile,
                ...(branch ? { branch } : {}),
                per_page: 100,
                page
              });
              const runs = response.data.workflow_runs;
              if (runs.length === 0) break;

              for (const run of runs) {
                if (run.id === context.runId) continue;
                const artifacts = await github.paginate(
                  github.rest.actions.listWorkflowRunArtifacts,
                  { owner, repo, run_id: run.id, per_page: 100 }
                );
                const match = artifacts.find(
                  artifact => artifact.name === artifactName && !artifact.expired
                );
                if (match) {
                  core.info(`Found ${artifactName} in run ${run.id} (${run.html_url}).`);
                  core.setOutput('run_id', String(run.id));
                  core.setOutput('artifact_id', String(match.id));
                  return;
                }
                core.info(`Run ${run.id} has no usable ${artifactName}; checking the next older run.`);
              }
            }

            core.setFailed(`No unexpired ${artifactName} artifact was found in this run or any previous run of ${workflowFile}${branch ? ` on branch ${branch}` : ''}.`);
  vmtest:
    needs: vmtest_find
    if: ${{ !cancelled() && needs.vmtest_find.result == 'success' }}
    strategy:
      fail-fast: false
      matrix:
        fw: [uefi]
    runs-on: ubuntu-24.04
    # Up to (1 + MAX_RETRIES) attempts x ~(2 x SWITCH_WAIT + boot) each
    timeout-minutes: 45
    permissions:
      actions: read
    env:
      SWITCH_WAIT: 120
      MAX_RETRIES: 2
    steps:
      - name: Download selected build artifact
        uses: actions/download-artifact@v4
        with:
          name: kibaos-build-x86_64
          run-id: ${{ needs.vmtest_find.outputs.run_id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          path: ./vmtest-artifact
      - name: Locate extracted ISO
        run: |
          ISO_PATH="$(find ./vmtest-artifact -type f -name '*.iso' -print -quit)"
          if [ -z "$ISO_PATH" ]; then
            echo "::error::The downloaded ZIP artifact did not contain an ISO file."
            find ./vmtest-artifact -maxdepth 4 -type f -print || true
            exit 1
          fi
          test -s "$ISO_PATH" || { echo "::error::Downloaded ISO is empty: $ISO_PATH"; exit 1; }
          echo "ISO_PATH=$ISO_PATH" >> "$GITHUB_ENV"
          echo "Using ISO from artifact: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
      - name: Boot ISO in QEMU and capture desktop screenshots
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm
          if [ -f /etc/apt/apt-mirrors.txt ]; then
            sudo sed -i '/azure\.archive\.ubuntu\.com/d' /etc/apt/apt-mirrors.txt
          fi
          sudo apt-get update
          sudo apt-get install -y qemu-system-x86 ovmf netcat-openbsd
          cat > qmp.py <<'PYQMP'
          import json, os, socket, sys

          ABS_MAX = 0x7fff

          def command(payload):
              sock = socket.socket(socket.AF_UNIX)
              sock.connect("qmp.sock")
              stream = sock.makefile("rw")
              stream.readline()  # QMP greeting
              def send(cmd):
                  stream.write(json.dumps(cmd) + "\n")
                  stream.flush()
                  while True:
                      response = json.loads(stream.readline())
                      if "return" in response or "error" in response:
                          return response
              result = send({"execute": "qmp_capabilities"})
              if "error" in result:
                  raise RuntimeError(result["error"])
              result = send(payload)
              sock.close()
              if "error" in result:
                  raise RuntimeError(result["error"])
              return result

          def click(px, py, width, height):
              ax = int(px * ABS_MAX / max(width - 1, 1))
              ay = int(py * ABS_MAX / max(height - 1, 1))
              events = [
                  {"type": "abs", "data": {"axis": "x", "value": ax}},
                  {"type": "abs", "data": {"axis": "y", "value": ay}},
                  {"type": "btn", "data": {"button": "left", "down": True}},
                  {"type": "btn", "data": {"button": "left", "down": False}},
              ]
              command({"execute": "input-send-event", "arguments": {"events": events}})

          if sys.argv[1] == "screendump":
              command({"execute": "screendump", "arguments": {
                  "filename": os.path.abspath(sys.argv[2]), "format": "png"
              }})
          elif sys.argv[1] == "click":
              click(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
          elif sys.argv[1] == "reset":
              command({"execute": "system_reset"})
          else:
              raise SystemExit("Usage: qmp.py screendump FILE | click X Y WIDTH HEIGHT | reset")
          PYQMP
          cat > qga.py <<'PYQGA'
          import json, socket, sys, time

          def run(path, args, tries=20):
              for _ in range(tries):
                  s = socket.socket(socket.AF_UNIX)
                  s.settimeout(3)
                  try:
                      s.connect("qga.sock")
                      f = s.makefile("rw")
                      def rpc(cmd):
                          f.write(json.dumps(cmd) + "\n"); f.flush()
                          return json.loads(f.readline())
                      sid = int(time.time() * 1000) & 0x7fffffff
                      if rpc({"execute": "guest-sync", "arguments": {"id": sid}}).get("return") != sid:
                          continue
                      pid = rpc({"execute": "guest-exec", "arguments": {
                          "path": path, "arg": args, "capture-output": True}})["return"]["pid"]
                      while True:
                          st = rpc({"execute": "guest-exec-status", "arguments": {"pid": pid}})["return"]
                          if st["exited"]:
                              return st.get("exitcode")
                          time.sleep(0.2)
                  except (OSError, ValueError, KeyError):
                      time.sleep(3)
                  finally:
                      s.close()
              raise SystemExit("guest agent never answered")

          rc = run("/usr/bin/pkill", ["-TERM", "-f", "kibaos-installer-gui"])
          print("pkill exit code:", rc, "(1 = no installer running -> assume login screen)")
          sys.exit(0 if rc == 0 else 1)
          PYQGA
          mkdir -p attempts
          ISO="$ISO_PATH"
          # UEFI only: OVMF via pflash.
          cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
          FW=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd -drive if=pflash,format=raw,file=vars.fd)

          vm_alive() { [ -f qemu.pid ] && kill -0 "$(cat qemu.pid)" 2>/dev/null; }
          start_vm() {
            rm -f qmp.sock qga.sock qemu.pid
            qemu-system-x86_64 -machine q35,accel=kvm:tcg -cpu max -smp 2 -m 4G "${FW[@]}" -cdrom "$ISO" -vga std -nic user -display none -device qemu-xhci -device usb-tablet -device virtio-serial-pci -chardev socket,id=qga0,path=qga.sock,server=on,wait=off -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 -qmp unix:qmp.sock,server,nowait -pidfile qemu.pid -daemonize
            for i in $(seq 1 30); do [ -S qmp.sock ] && [ -S qga.sock ] && break; sleep 1; done
          }
          stop_vm() {
            if vm_alive; then
              kill -TERM "$(cat qemu.pid)" 2>/dev/null || true
              sleep 2
              kill -KILL "$(cat qemu.pid)" 2>/dev/null || true
            fi
            rm -f qemu.pid
          }
          capture_probe() {
            python3 qmp.py screendump "$1"
          }
          # Returns 0 only if the installer was found and killed. A failure just
          # means "not running right now"; if it never succeeds during an attempt
          # we assume the VM is sitting at the login screen.
          kill_installer() { python3 qga.py; }

          SELECTED=""
          dir=""
          for attempt in $(seq 0 "$MAX_RETRIES"); do
            echo "=== ${{ matrix.fw }}: attempt $((attempt + 1))/$((MAX_RETRIES + 1)) ==="
            stop_vm
            start_vm
            dir="attempts/$(printf '%02d' "$((attempt + 1))")"
            mkdir -p "$dir"

            # Screen switch 1: white splash -> installer. No pixel checks, just wait.
            echo "Waiting ${SWITCH_WAIT}s for the splash to hand over to the installer..."
            sleep "$SWITCH_WAIT"
            vm_alive || { echo "QEMU exited early"; continue; }
            capture_probe "$dir/01-before-kill-${SWITCH_WAIT}s.png" || echo "screendump failed (non-fatal)"

            # Kill the installer if it is running. If it is not, assume the
            # VM is already past it (login screen / desktop).
            if kill_installer; then
              echo "Installer killed."
            else
              echo "Installer not running -- assuming already past it."
            fi

            # Screen switch 2: installer gone -> login screen / desktop. Wait again.
            echo "Waiting ${SWITCH_WAIT}s for the login screen / desktop..."
            sleep "$SWITCH_WAIT"
            vm_alive || { echo "QEMU exited early"; continue; }
            final="$dir/02-final-$((SWITCH_WAIT * 2))s.png"
            if capture_probe "$final" && [ -s "$final" ]; then
              SELECTED="$final"
              echo "Attempt $((attempt + 1)): selected $SELECTED"
              break
            fi
            echo "Attempt $((attempt + 1)): final screendump failed."
          done
          stop_vm

          mkdir -p shots
          cp "$dir"/*.png shots/ 2>/dev/null || true
          if [ -z "$SELECTED" ]; then
            echo "::error::${{ matrix.fw }}: no desktop screenshot after $((MAX_RETRIES + 1)) attempts"
            exit 1
          fi
          basename "$SELECTED" > shots/selected.txt
      - name: Upload screenshots
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v4
        with:
          name: vmtest-shots-${{ matrix.fw }}
          path: shots/
          if-no-files-found: ignore
          retention-days: 7
      - name: Upload all attempts (debugging)
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v4
        with:
          name: vmtest-attempts-${{ matrix.fw }}
          path: attempts/
          if-no-files-found: ignore
          retention-days: 3
  vmtest_commit:
    # One commit job per firmware (UEFI only for now), so screenshots are
    # uploaded separately and one failing never blocks the other.
    needs: vmtest
    if: ${{ !cancelled() && needs.vmtest.result != 'skipped' }}
    strategy:
      fail-fast: false
      matrix:
        fw: [uefi]
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: write
    concurrency:
      group: screenshot-commit-${{ matrix.fw }}
      cancel-in-progress: false
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Download ${{ matrix.fw }} screenshots
        continue-on-error: true
        uses: actions/download-artifact@v4
        with:
          name: vmtest-shots-${{ matrix.fw }}
          path: shots-in
      - name: Commit ${{ matrix.fw }} screenshots to assets/screenshots
        run: |
          FW="${{ matrix.fw }}"
          if ! compgen -G 'shots-in/*.png' >/dev/null; then
            echo "No ${FW} screenshots to commit."
            exit 0
          fi
          # Stage everything outside the repo tree so it survives a hard reset.
          STAGE="$RUNNER_TEMP/screens-stage"
          rm -rf "$STAGE"; mkdir -p "$STAGE/v${{ github.run_number }}/${FW}"
          cp shots-in/*.png "$STAGE/v${{ github.run_number }}/${FW}/"
          # Only a screenshot the VM test selected (installer killed, so not the login screen) becomes desktop-<fw>.png.
          if [ -f shots-in/selected.txt ] && [ -f "shots-in/$(cat shots-in/selected.txt)" ]; then
            cp "shots-in/$(cat shots-in/selected.txt)" "$STAGE/desktop-${FW}.png"
            # Back-compat: desktop.png keeps tracking the UEFI desktop.
            [ "$FW" = "uefi" ] && cp "$STAGE/desktop-${FW}.png" "$STAGE/desktop.png"
          else
            echo "${FW}: no selected desktop screenshot -- not updating desktop-${FW}.png."
          fi

          git config user.name "KibaOS OTA Bot"
          git config user.email "ota@kibaos.wolftech.tech"
          # No rebase/merge: binary files can't be merged and a failed rebase wedges
          # every retry. Each attempt resets to the latest remote tip and re-applies
          # the staged files on top, so the newest run always wins desktop-<fw>.png and
          # the per-run v<N>/<fw>/ folders never collide (each firmware touches its own paths).
          for i in 1 2 3 4 5 6; do
            git rebase --abort 2>/dev/null || true
            git fetch --no-tags origin "$GITHUB_REF_NAME"
            git reset --hard "origin/$GITHUB_REF_NAME"
            mkdir -p assets/screenshots
            cp -r "$STAGE"/. assets/screenshots/
            git add assets/screenshots
            if git diff --cached --quiet; then echo "Nothing new to commit."; exit 0; fi
            git commit -m "Add ${FW} VM screenshots for build v${{ github.run_number }}"
            if git push origin "HEAD:$GITHUB_REF_NAME"; then exit 0; fi
            echo "Push raced with another commit (attempt $i); retrying on the new tip..."
            sleep $((i * 5))
          done
          exit 1
  ota_x86_64:
    needs: latest_x86_64
    if: ${{ !inputs.skip_ota && needs.latest_x86_64.outputs.ota_needed == 'true' }}
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      actions: read
      contents: write
    env:
      ARCH: x86_64
      PATCH_NUM: ${{ needs.latest_x86_64.outputs.patch_num }}
      HEAD_SHA: ${{ needs.latest_x86_64.outputs.head_sha }}
    steps:
      - name: Download build artifact
        uses: actions/download-artifact@v4
        with:
          name: kibaos-build-x86_64
          run-id: ${{ needs.latest_x86_64.outputs.run_id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - name: Install tools
        run: |
          sudo tee /usr/local/bin/retry >/dev/null <<'EOF'
          #!/bin/bash
          for i in 1 2 3 4 5; do
            "$@" && exit 0
            c=$?
            [ "$c" -eq 23 ] && exit 23
            echo "retry $i/5 after exit $c: $1" >&2
            [ "$i" -lt 5 ] && sleep $((i * 10))
          done
          exit "$c"
          EOF
          sudo chmod +x /usr/local/bin/retry
          retry sudo apt-get install -y squashfs-tools sshpass rsync
      - name: Extract airootfs from ISO for OTA diffing
        run: |
          ISO=$(ls *.iso | head -1)
          mkdir -p /tmp/iso-mount /tmp/airootfs-extracted
          sudo mount -o loop "$ISO" /tmp/iso-mount
          SFS=$(find /tmp/iso-mount -name 'airootfs.sfs' | head -1)
          sudo unsquashfs -d /tmp/airootfs-extracted -processors "$(nproc)" "$SFS"
          sudo umount /tmp/iso-mount
          echo "Extracted file count: $(find /tmp/airootfs-extracted -type f | wc -l)"
      - name: Download previous build manifest from SourceForge
        env:
          SF_USER: ${{ secrets.SF_USER }}
          SSHPASS: ${{ secrets.SF_PASS }}
        run: |
          mkdir -p ~/.ssh
          retry ssh-keyscan -H frs.sourceforge.net >> ~/.ssh/known_hosts
          retry sshpass -e rsync -avP "$SF_USER@frs.sourceforge.net:/home/frs/project/kibaos/ota/last-build-manifest-${ARCH}.txt" ./last-build-manifest.txt || echo "No previous manifest found — this is a full baseline build."
      - name: Generate current build manifest
        run: |
          cd /tmp/airootfs-extracted
          sudo find . -type f -print0 | xargs -0 -P "$(nproc)" -n 64 sudo sha256sum 2>/dev/null | sed 's|sudo: ||' > "$GITHUB_WORKSPACE/current-build-manifest.txt" || true
          cd "$GITHUB_WORKSPACE"
          echo "Manifest entries: $(wc -l < current-build-manifest.txt)"
      - name: Compute changed files vs previous build
        id: diff
        run: |
          if [ ! -f last-build-manifest.txt ]; then
            echo "No previous manifest — skipping OTA patch generation for this baseline build."
            echo "has_changes=false" >> "$GITHUB_OUTPUT"
          else
            sort -k2 last-build-manifest.txt > prev-sorted.txt
            sort -k2 current-build-manifest.txt > curr-sorted.txt
            comm -13 prev-sorted.txt curr-sorted.txt | awk '{print $2}' > changed_files.txt
            CHANGED=$(wc -l < changed_files.txt)
            echo "Changed files: $CHANGED"
            head -20 changed_files.txt
            if [ "$CHANGED" -eq 0 ]; then echo "has_changes=false" >> "$GITHUB_OUTPUT"; else echo "has_changes=true" >> "$GITHUB_OUTPUT"; fi
          fi
          cp current-build-manifest.txt baseline-manifest.txt
      - name: Bundle OTA patch from extracted airootfs
        if: steps.diff.outputs.has_changes == 'true'
        run: |
          PATCH_DIR="ota-patch-${PATCH_NUM}-${ARCH}"
          mkdir -p "${PATCH_DIR}"
          sed 's|^\./||' changed_files.txt > changed_files_rel.txt
          sudo rsync -a --files-from=changed_files_rel.txt --ignore-missing-args /tmp/airootfs-extracted/ "${PATCH_DIR}/"
          sudo chmod -R a+rX "${PATCH_DIR}"
          sudo chown -R "$(id -u):$(id -g)" "${PATCH_DIR}" || true
          mkdir -p "${PATCH_DIR}/etc/kibaos"
          echo "${PATCH_NUM}" > "${PATCH_DIR}/etc/kibaos/patch-level"
          cd "${PATCH_DIR}"
          find . -type f -print0 | xargs -0 -P "$(nproc)" -n 64 sha256sum > "../kibaos-ota-${PATCH_NUM}-${ARCH}-manifest.txt"
          cd ..
          tar czf "kibaos-ota-${PATCH_NUM}-${ARCH}.tar.gz" "${PATCH_DIR}/"
          echo "Patch size: $(du -sh kibaos-ota-${PATCH_NUM}-${ARCH}.tar.gz | cut -f1)"
      - name: Sign OTA patch
        if: steps.diff.outputs.has_changes == 'true'
        env:
          OTA_SIGNING_KEY: ${{ secrets.OTA_SIGNING_KEY }}
        run: |
          echo "$OTA_SIGNING_KEY" | gpg --batch --import
          KEY_FP=$(gpg --list-keys --with-colons ota@kibaos.wolftech.tech | awk -F: '/^fpr/{print $10; exit}')
          echo "${KEY_FP}:6:" | gpg --import-ownertrust
          T="kibaos-ota-${PATCH_NUM}-${ARCH}.tar.gz"
          gpg --batch --yes --local-user ota@kibaos.wolftech.tech --detach-sign --armor "$T"
          gpg --verify "$T.asc" "$T" && echo "Signature verified OK." || { echo "Signature self-check failed!"; exit 1; }
      - name: Write latest-patch-level
        if: steps.diff.outputs.has_changes == 'true'
        run: echo "${PATCH_NUM}" > latest-patch-level
      - name: Upload OTA artifacts to SourceForge
        env:
          SF_USER: ${{ secrets.SF_USER }}
          SSHPASS: ${{ secrets.SF_PASS }}
        run: |
          mkdir -p ~/.ssh
          retry ssh-keyscan -H frs.sourceforge.net >> ~/.ssh/known_hosts
          R="$SF_USER@frs.sourceforge.net:/home/frs/project/kibaos/ota"
          retry sshpass -e rsync -avP baseline-manifest.txt "$R/last-build-manifest-${ARCH}.txt"
          if [ "${{ steps.diff.outputs.has_changes }}" == "true" ]; then
            retry sshpass -e rsync -avP "kibaos-ota-${PATCH_NUM}-${ARCH}.tar.gz" "kibaos-ota-${PATCH_NUM}-${ARCH}.tar.gz.asc" "kibaos-ota-${PATCH_NUM}-${ARCH}-manifest.txt" "$R/"
            echo "OTA patch ${PATCH_NUM} (${ARCH}) uploaded."
          else
            echo "No changes for ${ARCH} — only baseline manifest updated."
          fi
          if [ -f latest-patch-level ]; then retry sshpass -e rsync -avP latest-patch-level "$R/"; fi
          # Record which build SourceForge's OTA is now at, so a skipped-build run
          # can tell whether the newest GitHub artifact is newer than what's published.
          echo "${PATCH_NUM}" > last-ota-build.txt
          retry sshpass -e rsync -avP last-ota-build.txt "$R/last-ota-build-${ARCH}.txt"
      - name: Tag this build
        if: steps.diff.outputs.has_changes == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # Tag the commit the artifact was built from (not necessarily the current HEAD).
          gh api "repos/${{ github.repository }}/git/refs" \
            -f ref="refs/tags/ota-patch-${PATCH_NUM}" -f sha="${HEAD_SHA}" >/dev/null 2>&1 \
            && echo "Tagged ota-patch-${PATCH_NUM} at ${HEAD_SHA}." \
            || echo "Tag ota-patch-${PATCH_NUM} already exists or could not be created."