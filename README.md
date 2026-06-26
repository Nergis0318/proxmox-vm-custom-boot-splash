# Proxmox VM Custom Boot Splash

Proxmox VE 호스트에서 UEFI(OVMF) 펌웨어의 부팅 로고를 커스텀 이미지로 교체하는 도구입니다.

VM을 켤 때 표시되는 TianoCore / Proxmox 로고(검은 화면 중앙)를 회사 로고 등으로 바꿀 수 있습니다.

## 동작 원리

UEFI VM은 부팅 초기에 **OVMF CODE 펌웨어** 안에 포함된 BMP 이미지를 화면에 표시합니다.

```
VM 전원 ON → OVMF_CODE*.fd 로고 표시 → OS 부트로더/로더 → 게스트 OS
```

이 프로젝트는 `/usr/share/pve-edk2-firmware/` 에 설치된 OVMF 펌웨어 이미지를 수정합니다.

> **주의:** `OVMF_VARS*.fd` 파일은 NVRAM(부팅 순서, Secure Boot 키 등)만 저장하며 로고가 들어 있지 않습니다. 패치 대상이 아닙니다.

## 요구 사항

| 항목      | 내용                                          |
| --------- | --------------------------------------------- |
| 실행 위치 | **Proxmox VE 호스트** (게스트 VM 내부가 아님) |
| 권한      | `root`                                        |
| OS        | Proxmox VE 7 / 8 / 9 (Debian 기반)            |
| Python    | 3.10+ (`python3`, `python3-pil` 또는 Pillow)  |
| VM 타입   | UEFI 부팅 VM (`efidisk0` 설정 필요)           |

## 빠른 시작

```bash
# 저장소를 Proxmox 호스트로 복사한 뒤
chmod +x scripts/*.sh

# 권장: quick patch 실패 시 자동으로 소스 빌드
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png --auto-build
```

적용 후 VM을 **중지 → 시작**해야 새 로고가 보입니다. 실행 중인 VM에는 즉시 반영되지 않습니다.

## 적용 방식

### 1) Quick Patch (빠른 패치)

기존 펌웨어 `.fd` 파일에서 BMP 로고를 찾아 **같은 크기**로 바이너리 교체합니다.

- 장점: 수 초 내 완료
- 단점: Proxmox 8+ 에서 로고가 LZMA 압축되어 있으면 실패할 수 있음

```bash
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png
```

### 2) Source Build (소스 빌드) — Proxmox 8+ 권장

`pve-edk2-firmware` 소스를 클론해 `debian/Logo.bmp` 를 교체한 뒤 **x64 OVMF CODE 이미지만** 재빌드·설치합니다.

- 장점: 압축된 펌웨어에서도 확실히 적용, 로고 크기 자유
- 단점: 첫 빌드에 10~30분 소요 (서브모듈 다운로드 포함)
- 기본값(`OVMF_ONLY=1`): `OVMF_CODE_4M.fd`, `OVMF_CODE_4M.secboot.fd` 만 교체 (VARS/NVRAM 미변경)

```bash
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png --build
```

전체 아키텍처 패키지를 빌드하려면:

```bash
sudo OVMF_ONLY=0 ./scripts/apply-custom-boot-logo.sh ./logo.png --build
```

## 사용 예시

### 특정 VM에 맞는 펌웨어만 패치

```bash
# VM이 사용하는 CODE 펌웨어 파일 확인
./scripts/detect-vm-firmware.sh 101

# 해당 VM용 파일만 패치 (실패 시 자동 빌드)
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png --vmid 101 --auto-build
```

### 특정 펌웨어 파일만 지정

```bash
# Windows 11 + Secure Boot VM은 보통 secboot 변형이 필요
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png \
  --files OVMF_CODE_4M.secboot.fd
```

### 원본 펌웨어 복구

```bash
sudo ./scripts/apply-custom-boot-logo.sh --restore
```

백업 위치: `/var/lib/pve-custom-boot-logo/backups/`

### 변경 없이 점검 (dry-run)

```bash
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png --dry-run
```

## 로고 이미지 가이드

- **입력 형식:** PNG, JPG, BMP 등 (Pillow 지원 형식)
- **내부 변환:** UEFI 호환 24-bit BMP
- **Quick patch:** 기존 펌웨어 로고와 **동일한 픽셀 크기**로 자동 리사이즈
- **Build:** 임의 크기 가능 (권장: 가로 200~400px, 비율 유지)
- **배경:** 투명 PNG는 검은 배경 위에 합성됨

수동 변환:

```bash
python3 lib/prepare_logo.py ./logo.png ./Logo.bmp --width 240 --height 80
```

## 펌웨어 파일 참고

Proxmox에 설치되는 주요 파일 (`/usr/share/pve-edk2-firmware/`):

| 파일                      | 용도                              |
| ------------------------- | --------------------------------- |
| `OVMF_CODE_4M.fd`         | 일반 UEFI VM (4MB)                |
| `OVMF_CODE_4M.secboot.fd` | Secure Boot + SMM VM              |
| `OVMF_VARS_4M.fd`         | NVRAM (로고 없음)                 |
| `OVMF_VARS_4M.ms.fd`      | MS 키 사전 등록 NVRAM (로고 없음) |

VM 설정 예시 (`/etc/pve/qemu-server/101.conf`):

```
machine: q35
efidisk0: local-lvm:vm-101-disk-0,efitype=4m,pre-enrolled-keys=1
```

위와 같이 `pre-enrolled-keys=1` 이 있으면 `OVMF_CODE_4M.secboot.fd` 가 사용됩니다.

## 문제 해결

### `No embedded BMP logos found in firmware`

Proxmox 8 이상에서 흔히 발생합니다. 로고가 UEFI 볼륨 안에 LZMA 압축되어 plain BMP 스캔으로 찾을 수 없기 때문입니다.

```bash
# 원인 확인
sudo python3 lib/patch_firmware.py diagnose \
  /usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd

# 해결: 소스 빌드
sudo ./scripts/apply-custom-boot-logo.sh ./logo.png --build
```

### 로고가 바뀌지 않음

1. VM을 **완전히 중지** 후 다시 시작했는지 확인
2. `detect-vm-firmware.sh <vmid>` 로 올바른 CODE 파일을 패치했는지 확인
3. Secure Boot VM이면 `OVMF_CODE_4M.secboot.fd` 포함 여부 확인
4. `pve-edk2-firmware` 패키지 업데이트 후 재적용 필요할 수 있음

### 빌드 의존성 오류 / `proxmox-ve` 제거 경고

**절대 설치하면 안 되는 패키지 (라이브 Proxmox 노드):**

| 패키지         | 이유                                              |
| -------------- | ------------------------------------------------- |
| `gcc-multilib` | `proxmox-ve`, `pve-qemu-kvm` 제거 유발            |
| `qemu-utils`   | `pve-qemu-kvm` 과 충돌 (`qemu-img`는 이미 설치됨) |

최신 스크립트는 대신 `gcc-i686-linux-gnu`(32비트 크로스 컴파일러)를 사용하고, `apt` 설치 전 Proxmox 패키지 제거 여부를 검사합니다.

수동 설치가 필요할 때:

```bash
apt-get install -y git build-essential bc debhelper dosfstools \
  acpica-tools mtools nasm uuid-dev xorriso \
  python3 python3-pexpect python3-pil gcc-i686-linux-gnu
```

### 빌드 실패 (subhook submodule)

`build-firmware.sh` 가 `subhook` 저장소 URL을 자동으로 수정합니다. 그래도 실패하면:

```bash
cd /var/lib/pve-custom-boot-logo/build/pve-edk2-firmware
git submodule sync --recursive
git submodule update --init --recursive
```

## 프로젝트 구조

```
proxmox-vm-custom-boot-splash/
├── .github/workflows/
│   └── build-firmware.yml          # GHCR 이미지 빌드 + OVMF 빌드 + Release
├── docker/
│   └── Dockerfile                  # Debian 13(PVE9) 빌드 환경 이미지
├── assets/
│   └── logo.png                    # CI가 사용하는 로고 (교체하세요)
├── scripts/
│   ├── apply-custom-boot-logo.sh   # 메인 진입점
│   ├── build-firmware.sh           # pve-edk2-firmware 소스 빌드
│   └── detect-vm-firmware.sh       # VM별 펌웨어 파일 진단
├── lib/
│   ├── prepare_logo.py             # 이미지 → UEFI BMP 변환
│   ├── patch_firmware.py           # 펌웨어 BMP 탐색·패치·진단
│   └── uefi_lzma.py                # UEFI LZMA 압축 해제 헬퍼
├── tests/
│   └── test_patch_firmware.py
├── requirements.txt
└── README.md
```

## 저수준 CLI

```bash
# 펌웨어 내 BMP 영역 스캔
python3 lib/patch_firmware.py scan /usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd

# 기존 로고 추출
python3 lib/patch_firmware.py extract \
  /usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd /tmp/original-logo.bmp

# 단위 테스트
python3 tests/test_patch_firmware.py -v
```

## Docker 빌드 / GitHub Actions

라이브 Proxmox 노드에서 직접 빌드하는 대신, **깨끗한 Debian 13(Proxmox VE 9 베이스) 컨테이너**에서 OVMF 이미지를 빌드할 수 있습니다. 호스트의 `proxmox-ve`/`pve-qemu-kvm` 패키지를 건드리지 않으므로 안전합니다.

> 빌드 결과물(`OVMF_CODE_4M.fd`)은 **호스트의 Debian/Proxmox 버전과 맞아야** 합니다. 이 파이프라인은 PVE 9(Debian 13 "trixie") 기준입니다.

### 로고 준비

CI는 `assets/logo.png` 를 사용합니다. 기본값은 플레이스홀더이므로 **자신의 로고로 교체**하세요 (PNG/JPG/BMP, 권장 가로 200~400px).

### 1) 로컬 Docker 빌드

```bash
# 빌드 환경 이미지 빌드
docker build -t pve-ovmf-build-env ./docker

# 리포를 마운트해 OVMF CODE 이미지 빌드
docker run --rm -v "$PWD:/workspace" \
  -e SKIP_DEPS=1 \
  -e GIT_URL=https://git.proxmox.com/git/pve-edk2-firmware.git \
  -e GIT_DEPTH=1 \
  -e BUILD_ROOT=/workspace/_build \
  pve-ovmf-build-env \
  bash scripts/build-firmware.sh assets/logo.png

# 결과물
ls _build/edk2-work/debian/ovmf-install/OVMF_CODE_4M*.fd
```

생성된 `.fd` 파일을 Proxmox 호스트의 `/usr/share/pve-edk2-firmware/` 로 복사한 뒤 VM을 중지→시작하면 새 로고가 적용됩니다. (먼저 원본 백업 권장)

### 2) GitHub Actions (`.github/workflows/build-firmware.yml`)

| 트리거         | 동작                                                                                                              |
| -------------- | ----------------------------------------------------------------------------------------------------------------- |
| `master` 푸시  | 빌드 환경 이미지를 **GHCR**(`ghcr.io/<owner>/<repo>/build-env`)에 푸시 → 컨테이너에서 OVMF 빌드 → 아티팩트 업로드 |
| `v*` 태그 푸시 | 위 + `.fd` 파일을 **GitHub Release** 자산으로 첨부                                                                |
| 수동 실행      | `workflow_dispatch` 입력으로 다른 로고 경로 지정 가능                                                             |

릴리스 생성 예시:

```bash
git tag v1.0.0
git push origin v1.0.0   # Release 에 OVMF_CODE_4M.fd / .secboot.fd / SHA256SUMS 첨부
```

> 빌드 환경 이미지가 GHCR에 푸시되므로(빌드 의존성 캐시), 이후 빌드는 더 빨라집니다. `git://` 대신 `https://` 로 클론하도록 `GIT_URL` 을 오버라이드합니다.

## 주의 사항

- **호스트 전체 펌웨어를 수정**합니다. 해당 Proxmox 노드의 UEFI VM 부팅 화면에 공통 적용됩니다.
- `pve-edk2-firmware` 패키지 업그레이드 시 커스텀 로고가 **덮어씌워질 수** 있습니다. 업데이트 후 재적용이 필요할 수 있습니다.
- 펌웨어 수정은 부팅 실패 위험이 있으므로, 스크립트가 자동으로 백업을 생성합니다.
- Windows 11 설치/업데이트와 Secure Boot 조합에서 펌웨어 변경이 영향을 줄 수 있습니다. 문제 발생 시 `--restore` 로 복구하세요.

## 참고

- [Proxmox Forum: VM booting logo custom](https://forum.proxmox.com/threads/proxmox-8-vm-booting-logo-custom.166932/)
- [pve-edk2-firmware (Proxmox Git)](https://git.proxmox.com/?p=pve-edk2-firmware.git)
- [TianoCore EDK II](https://www.tianocore.org/)

## 라이선스

이 저장소의 스크립트는 자유롭게 사용·수정할 수 있습니다. `pve-edk2-firmware` 빌드 시 해당 프로젝트의 라이선스가 적용됩니다.
