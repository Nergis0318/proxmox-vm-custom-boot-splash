# Proxmox VM Custom Boot Splash

Proxmox VE의 UEFI(OVMF) VM을 켤 때 나오는 부팅 로고(검은 화면 중앙의 TianoCore / Proxmox 로고)를 **내 로고로 바꿔주는** 도구입니다.

<img width="1599" height="711" alt="image" src="https://github.com/user-attachments/assets/c776ab38-eb2b-4a61-9257-b102736139ec" />

이 저장소를 **포크 → 내 로고 이미지 1장 교체 → GitHub Actions가 자동 빌드 → Proxmox 호스트에서 한 줄 설치**, 이 흐름이 핵심입니다. 호스트에서 직접 컴파일(10~30분)할 필요가 없습니다.

```text
포크 → assets/logo.png 교체 → 태그 푸시(Actions 빌드) → Release 생성 → Proxmox 호스트:  install-from-release.sh → VM 중지·시작
```

> 빌드는 GitHub의 깨끗한 컨테이너에서 일어나므로 Proxmox 호스트의 `proxmox-ve` / `pve-qemu-kvm` 패키지를 전혀 건드리지 않습니다.

---

## 핵심 사용법 — 포크해서 내 로고로 빌드하기

### 1단계. 이 저장소를 포크

GitHub에서 오른쪽 위 **Fork** 버튼을 눌러 내 계정으로 복사합니다. 이후 모든 작업은 **내 포크**에서 진행합니다.

### 2단계. 내 로고로 교체

포크한 저장소에서 [`assets/logo.png`](assets/logo.png) 를 내 로고로 바꿔 커밋합니다. 파일명·경로는 그대로 두고 내용만 교체하면 됩니다.

웹에서 바로: 포크의 `assets/logo.png` 화면 → 연필/`...` 메뉴 → **Upload / Replace** 로 내 이미지 업로드.

또는 로컬에서:

```bash
git clone https://github.com/<내계정>/proxmox-vm-custom-boot-splash.git
cd proxmox-vm-custom-boot-splash
cp ~/my-company-logo.png assets/logo.png
git commit -am "Use my company logo"
git push
```

#### 로고 이미지 권장 사항

- **형식:** PNG / JPG / BMP 등 Pillow 지원 형식
- **크기:** 가로 200~400px 내외, 원본 비율 유지 (빌드 방식은 크기 제약이 없지만 너무 크면 화면을 가립니다)
- **배경:** 투명 PNG는 **검은 배경** 위에 합성됨 (부트 화면이 검정)
- **색상:** 어두운 배경에서 잘 보이는 밝은 색 권장

### 3단계. Release 생성 → GitHub Actions로 빌드

포크에는 빌드 워크플로([`.github/workflows/build-firmware.yml`](.github/workflows/build-firmware.yml))가 함께 복사되어 있습니다.

**먼저 한 번만:** 포크 저장소의 **Actions** 탭에 들어가 워크플로 실행을 **활성화**합니다. (GitHub는 포크의 Actions를 기본 비활성화합니다.)

그다음 **버전 태그를 푸시**하면 빌드가 돌고 결과물이 **Release 자산**으로 첨부됩니다:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Actions가 끝나면 포크의 **Releases** 에 다음 파일이 올라옵니다:

- `OVMF_CODE_4M.fd` — 일반 UEFI VM용 펌웨어
- `OVMF_CODE_4M.secboot.fd` — Secure Boot VM용 펌웨어
- `SHA256SUMS` — 무결성 검증용 체크섬

> **로고만 바꿔 다시 빌드:** 새 로고로 교체·커밋한 뒤 새 태그(`v1.0.1` …)를 푸시하면 됩니다.
>
> **태그 없이 미리 확인:** `master` 푸시나 Actions 탭의 **Run workflow**(`workflow_dispatch`)로도 빌드되며, 이 경우 Release 대신 **Artifacts** 로 결과물이 올라옵니다. 정식 배포(Release)는 태그 푸시로 만드세요.

### 4단계. Proxmox 호스트에 설치

Proxmox VE 호스트에 **root**로 접속해, 내 포크를 클론하고 설치 스크립트를 실행합니다:

```bash
git clone https://github.com/<내계정>/proxmox-vm-custom-boot-splash.git
cd proxmox-vm-custom-boot-splash

# 내 포크의 최신 Release에서 펌웨어를 받아 설치
sudo ./scripts/install-from-release.sh
```

스크립트가 **클론한 저장소의 git origin을 보고 내 포크의 Release를 자동으로** 대상으로 삼습니다. 별도 옵션이 필요 없습니다.

하는 일:

1. 내 포크 Release에서 `SHA256SUMS` 와 `.fd` 파일을 다운로드 (`curl`/`wget`만 있으면 됨)
2. SHA256 체크섬 **검증**
3. 호스트에 **이미 존재하는** OVMF CODE 파일만 (최초 1회 원본 백업 후) 교체
4. 안내 출력

마지막으로, 적용한 **VM을 중지 → 시작**하면 새 로고가 보입니다. (실행 중인 VM은 펌웨어를 다시 읽지 않습니다.)

```bash
# 특정 버전 고정
sudo ./scripts/install-from-release.sh --version v1.0.0

# 다운로드·검증만 하고 설치는 안 함 (미리보기)
sudo ./scripts/install-from-release.sh --dry-run
```

> 호스트에 저장소를 클론하지 않고 다른 포크를 대상으로 하려면 `--repo <owner>/<repo>` 또는 환경변수 `GITHUB_REPO` 로 지정할 수 있습니다.

---

## 원래 로고로 복구

```bash
sudo ./scripts/apply-custom-boot-logo.sh --restore
```

설치 스크립트가 최초 적용 시 원본을 `/var/lib/pve-custom-boot-logo/backups/` 에 백업해 두며, 복구는 이 백업을 되돌립니다. 복구 후에도 VM을 **중지 → 시작** 하세요.

## 요구 사항

| 항목      | 내용                                          |
| --------- | --------------------------------------------- |
| 실행 위치 | **Proxmox VE 호스트** (게스트 VM 내부가 아님) |
| 권한      | `root`                                        |
| OS        | Proxmox VE 9 (Debian 13 "trixie") 기준        |
| 다운로드  | `curl` 또는 `wget`                            |
| VM 타입   | UEFI 부팅 VM (`efidisk0` 설정 필요)           |

> 빌드 결과물은 **호스트의 Proxmox/Debian 버전과 맞아야** 합니다. 이 파이프라인은 PVE 9(Debian 13) 기준입니다. PVE 7/8을 쓴다면 빌드 베이스([`docker/Dockerfile`](docker/Dockerfile))를 해당 버전에 맞춰 조정하세요.

---

## 대안: 호스트에서 직접 적용 (Actions 없이)

Release 빌드 흐름이 가장 권장되지만, 호스트에서 바로 적용할 수도 있습니다.

```bash
# 빠른 패치 시도 → 안 되면(Proxmox 8+ LZMA 압축) 자동으로 소스 빌드(10~30분)
sudo ./scripts/apply-custom-boot-logo.sh ./my-logo.png --auto-build
```

- **Quick Patch:** 기존 펌웨어의 BMP를 같은 크기로 바이너리 교체 (수 초). Proxmox 8+ 에서는 로고가 LZMA 압축되어 실패할 수 있습니다.
- **Source Build (`--build`):** `pve-edk2-firmware` 소스를 받아 호스트에서 재빌드. 확실하지만 첫 빌드가 오래 걸리고 빌드 의존성이 필요합니다.
- **특정 VM만:** `./scripts/detect-vm-firmware.sh <vmid>` 로 해당 VM의 CODE 파일을 확인한 뒤 `--vmid <id>` 로 적용.

자세한 옵션은 `sudo ./scripts/apply-custom-boot-logo.sh --help` 와 [AGENTS.md](AGENTS.md) 를 참고하세요.

---

## 대안: 로컬 도커로 빌드 (Actions 없이)

GitHub Actions를 쓰지 않고 **내 PC에서 도커로 직접** `.fd` 를 뽑을 수도 있습니다. Actions가 하는 일과 동일한 빌드를 로컬에서 재현하는 경로로, 빌드 파이프라인을 디버깅하거나 GitHub 없이 결과물이 필요할 때 유용합니다.

> 전제: **Docker가 Linux 컨테이너 모드**로 실행 중이어야 합니다(이미지가 `debian:trixie-slim` 기반).

### 1단계. 빌드 환경 이미지 만들기

[`docker/Dockerfile`](docker/Dockerfile) 은 EDK2 빌드 의존성만 구워둔 이미지입니다. 소스는 들어가지 않고 실행 시 마운트합니다.

```bash
docker build -t pve-build-env docker
```

### 2단계. 컨테이너 안에서 펌웨어 빌드

저장소 루트에서 실행합니다.

```bash
docker run --rm -v "$PWD:/workspace" \
  -e SKIP_DEPS=1 -e OVMF_ONLY=1 \
  -e GIT_URL=https://git.proxmox.com/git/pve-edk2-firmware.git \
  -e GIT_DEPTH=1 -e BUILD_ROOT=/workspace/_build \
  pve-build-env bash scripts/build-firmware.sh assets/logo.png
```

> Windows PowerShell에서는 `$PWD` 를 `${PWD}` 로, 줄 끝 `\` 를 백틱(`` ` ``)으로 바꾸세요.

주요 환경변수(Actions의 [`build-firmware.yml`](.github/workflows/build-firmware.yml) 과 동일):

- `SKIP_DEPS=1` — 의존성은 이미지에 구워져 있으므로 apt 설치 생략
- `OVMF_ONLY=1` — x64 `OVMF_CODE_4M(.secboot).fd` 만 빌드
- `GIT_URL=https://…` — `git://` 이 막힌 환경이 많아 https 로 클론
- `GIT_DEPTH=1` — 펌웨어 소스 + 서브모듈을 얕게 클론(빠름)
- `BUILD_ROOT=/workspace/_build` — **마운트된 경로**로 지정해야 결과물이 호스트에 남음(기본값은 컨테이너 내부라 `--rm` 시 사라짐)

### 결과물 위치

```text
_build/edk2-work/debian/ovmf-install/OVMF_CODE_4M.fd
_build/edk2-work/debian/ovmf-install/OVMF_CODE_4M.secboot.fd
```

이 `.fd` 파일을 Proxmox 호스트의 `/usr/share/pve-edk2-firmware/` 로 (원본 백업 후) 복사해 적용합니다. **호스트의 PVE/Debian 버전과 맞아야** 합니다. 로고만 바꿔 다시 빌드하려면 `assets/logo.png` 를 교체하고 2단계만 다시 실행하면 되고, `_build` 디렉터리를 그대로 두면 다음 빌드부터 클론을 재사용해 빨라집니다.

> 첫 빌드는 pve-edk2-firmware + 서브모듈(~1.8 GB) 클론과 EDK2 컴파일로 **10~30분 이상** 걸릴 수 있습니다.

## 문제 해결

### 포크에서 Actions가 안 돌아요

- 포크의 **Actions** 탭에서 워크플로를 **활성화**했는지 확인 (포크는 기본 비활성).
- Release가 안 생기면: Release는 **`v*` 태그 푸시**에서만 만들어집니다. `master` 푸시/수동 실행은 Artifacts만 올립니다.
- GHCR 빌드 환경 이미지 푸시 단계는 기본 `GITHUB_TOKEN`(`packages: write`)으로 동작합니다. 조직 정책으로 막혀 있다면 저장소 Settings → Actions 권한을 확인하세요.

### `install-from-release.sh` 가 Release를 못 찾음

- 포크에 **Release가 실제로 생성**됐는지(태그를 푸시했는지) 확인.
- 호스트에서 **내 포크를 클론**해 실행했는지 확인 (origin 자동 인식). 아니라면 `--repo <owner>/<repo>` 로 지정.
- 저장소가 비공개면 자산 다운로드가 인증을 요구할 수 있습니다. 공개 저장소를 권장합니다.

### 로고가 안 바뀜

1. 적용한 VM을 **완전히 중지** 후 다시 시작했는지 확인.
2. Windows 11 + Secure Boot VM은 보통 `OVMF_CODE_4M.secboot.fd` 가 필요합니다. 해당 파일이 호스트에 있어 교체됐는지 확인.
3. `pve-edk2-firmware` 패키지 업그레이드 시 커스텀 로고가 덮어써질 수 있습니다. 업데이트 후 재설치하세요.

### 호스트에서 직접 빌드(`--build`) 시 의존성 경고

라이브 Proxmox 노드에서는 **절대** `gcc-multilib` / `qemu-utils` 를 설치하지 마세요(`proxmox-ve`/`pve-qemu-kvm` 제거 유발). 스크립트는 대신 `gcc-i686-linux-gnu` 를 쓰고 보호 패키지 제거 여부를 검사합니다. 이것이 호스트 직접 빌드 대신 **Actions 빌드를 권장하는 이유**이기도 합니다.

## 프로젝트 구조

```text
proxmox-vm-custom-boot-splash/
├── .github/workflows/
│   └── build-firmware.yml          # Actions: 컨테이너에서 OVMF 빌드 + Release 첨부
├── assets/
│   └── logo.png                    # ★ 내 로고로 교체하는 파일
├── docker/
│   └── Dockerfile                  # 빌드 환경 이미지(Debian 13 / PVE 9)
├── scripts/
│   ├── install-from-release.sh     # ★ 호스트: Release 펌웨어 다운로드·설치
│   ├── apply-custom-boot-logo.sh   # 호스트: 직접 패치/빌드 + 복구(--restore)
│   ├── build-firmware.sh           # pve-edk2-firmware 소스 빌드
│   └── detect-vm-firmware.sh       # VM별 펌웨어 파일 진단
└── lib/                            # 로고 변환·펌웨어 패치 파이썬 헬퍼
```

## 참고

- [Proxmox Forum: VM booting logo custom](https://forum.proxmox.com/threads/proxmox-8-vm-booting-logo-custom.166932/)
- [pve-edk2-firmware (Proxmox Git)](https://git.proxmox.com/?p=pve-edk2-firmware.git)
- [TianoCore EDK II](https://www.tianocore.org/)

## 라이선스

이 저장소의 스크립트는 자유롭게 사용·수정할 수 있습니다. `pve-edk2-firmware` 빌드 시 해당 프로젝트의 라이선스가 적용됩니다.
