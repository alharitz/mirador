Dokumen 02/ 9 September 2026/ Fase 1/ Status: Blok 0 selesai

# Mirador v0.1

**M**onitoring **I**mpostor **R**egistrations **A**nd **D**omain **O**wnership **R**ecords

Catatan: Implementasi saat ini menggunakan Rust, mengganti tumpukan Go aslinya. dnstwist tetap sebagai alat Python eksternal yang dipin. Batas fase 1 tetap pasif: tidak ada HTTP ke domain kandidat.

Batas fase 1 secara lengkap: apa yang dibangun, apa yang sengaja tidak, dan bentuk teknis yang membuat fase 2 nanti jadi **penambahan, bukan pembongkaran**.

dns + ct log tanpa http ke penyerang api-first 4 sinyal verdict

[01 Batas](#batas) [02 Irama](#irama) [03 Sumber](#sumber) [04 Probe & kondisi](#probe) [05 Batas modul](#modul) [06 Skema](#skema) [07 Verdict](#verdict) [08 Umur domain](#umur) [09 Mute](#mute) [10 CLI](#cli) [11 Daftar fitur](#fitur) [12 Belum diputus](#terbuka)

Konteks produk, arsitektur umum, dan peta fase ada di dokumen 01. Checklist kerjanya di dokumen 03.

01 — Batas

## Apa yang masuk, dan apa yang sengaja tidak

Batas ini dipersempit dengan susah payah. Setiap penambahan setelah ini harus lolos satu tes: apakah ia melayani **deteksi perubahan** atau **verdict yang bisa dijelaskan**. Kalau tidak, ia bukan fase 1.

### Masuk v0.1

- Daftar brand yang dijaga
- Generate kandidat pakai dnstwist — tidak ditulis ulang
- Resolve A, MX, NS
- Simpan kondisi per domain, riwayat append-only
- Bandingkan tiap siklus, deteksi transisi
- Verdict dari policy YAML, empat sinyal
- Umur domain: observasi sendiri + RDAP terbatas
- Mute dan acknowledge, plus impor massal aset sendiri
- Keluaran JSONL dan webhook
- Sumber kedua: aliran CT log
- **HTTP API** — kontrak yang nanti dipakai frontend

### Tidak masuk v0.1

- HTTP apa pun ke domain yang dipantau — tanpa screenshot, kemiripan konten, atau hash favicon
- Pencocokan registrant lewat RDAP *(berbeda dari penarikan tanggal registrasi — lihat bagian 08)*
- Pemantauan kedaluwarsa domain sendiri
- Frontend — aplikasi terpisah, fase 2. API-nya sendiri masuk fase 1.
- Standing verdict dan disposition analis
- Multi-tenant

### Kenapa fase 1 tidak pernah menyentuh infrastruktur penyerang

Seluruh fase 1 cuma melakukan dua hal ke luar: **DNS lookup** (ke resolver, bukan ke server penyerang) dan **membaca CT log publik**. Satu tambahan kecil di bagian 08 adalah request RDAP — itu ke *registry*, juga bukan ke penyerang.

Ini bukan kompromi; ini yang membuat fase 1 aman dikerjakan sendirian dari rumah. Seluruh urusan OPSEC — fingerprinting pengunjung, pemblokiran, pencatatan oleh hoster, cloaking — tertunda ke fase 2, saat deployment sudah di cloud dan IP yang terpapar bukan IP rumah.

02 — Irama

## Tiga jadwal yang berbeda, dan kenapa harus berbeda

Bagian yang paling sering salah dirancang. Generate, probe, dan CT punya biaya dan urgensi yang jauh berbeda. Menjalankan ketiganya di satu loop berarti membayar harga yang paling mahal untuk semuanya.

**Gambar 1 — empat irama dalam tiga hari.** Konsekuensi desainnya satu: `next_check_at` disimpan per kandidat di database, bukan "loop yang menyapu seluruh tabel". Siklus mengambil yang jatuh tempo saja — dan restart tidak menghasilkan gelombang lookup.

Angka 6 / 24 jam di atas adalah tebakan awal, **bukan hasil pengukuran**. Blok 1 yang menentukannya, setelah volume kandidat dan waktu resolve yang sebenarnya diketahui.

03 — Sumber

## Satu interface, dua implementasi

internal/core · internal/source kontrak plugin

```
// internal/core — tidak mengimpor apa pun
type Candidate struct {
    FQDN          string            // lowercase, punycode, tanpa trailing dot
    BrandID       int64
    DiscoveredVia string            // "dnstwist" | "ct"
    Hint          map[string]string // milik sumber, sengaja tidak dibaca hilir
}

// internal/source
type Source interface {
    Name() string
    Run(ctx context.Context, out chan<- core.Candidate) error
}
```

`Hint` sengaja tidak dibaca hilir. Kalau suatu hari ada field khusus-sumber yang *harus* dibaca verdict, itu tanda garis pluginnya bocor — lebih baik ketahuan sebagai keputusan sadar daripada menyelinap masuk.

### Sumber permutasi: cara dnstwist dipanggil

dnstwist mengerjakan dua hal: menyusun nama permutasi, dan meresolve nama-nama itu lewat DNS. Mirador cuma butuh yang pertama — resolusi adalah tugas `internal/probe`, yang punya konkurensi, cache, dan rate limit sendiri. Masalahnya dnstwist tidak punya flag untuk mematikan DNS: `--format json` *selalu* meresolve seluruh kandidat sebelum mencetak. Yang bebas DNS cuma `--format list`, dan itu hanya mencetak nama — label `fuzzer`-nya hilang.

Jalan keluarnya memakai `--fuzzers`: panggil sekali per algoritma, dan labelnya kita yang pasang dari flag yang dikirim. Bebas DNS, dan label tekniknya tetap ada.

internal/source/dnstwistdiuji 9 Sep 2026 · dnstwist 20250130

```
# dipakai: sekali per fuzzer, tanpa DNS, label dipasang sendiri
dnstwist --format list --fuzzers homoglyph    bca.co.id
dnstwist --format list --fuzzers bitsquatting bca.co.id
dnstwist --format list --fuzzers addition     bca.co.id
...

# tidak dipakai: label fuzzer-nya ada, tapi harganya meresolve
# seluruh kandidat — kerja dobel dengan probe kita sendiri
dnstwist --format json bca.co.id
```

Konsekuensinya di Dockerfile: `dnstwist` dipasang **tanpa extra `full`**. Seluruh dependency-nya (dnspython, tld, idna) ada di extra itu, dan tidak satu pun dibutuhkan oleh `--format list`. Peringatan *"DNS features are limited"* yang muncul tanpa dnspython keluar ke **stderr**, jadi stdout tetap bersih untuk di-parse.

Label fuzzer bukan hiasan: `homoglyph` jauh lebih mencurigakan daripada `addition`, jadi ia layak dipertimbangkan sebagai sinyal tambahan di policy. Pengaman yang murah: jalankan juga satu `--format list` polos dan bandingkan — nama yang tidak tertangkap satu pun fuzzer berarti dnstwist menambah algoritma baru, dan itu harus ketahuan, bukan hilang diam-diam.

### Sumber CT: memilih log mana yang di-tail

Certificate Transparency **bukan satu database**. Ia sekumpulan log append-only yang dijalankan operator berbeda — Google, Cloudflare, Let's Encrypt, DigiCert, Sectigo, dan lainnya. Setiap CA yang menerbitkan sertifikat wajib mengirimkannya ke beberapa log supaya browser mau menerima sertifikat itu. Tidak ada satu feed global yang tinggal di-subscribe: **Anda memilih log mana yang mau diikuti.**

| Yang harus diputuskan | Konsekuensinya |
| --- | --- |
| Berapa banyak log | Terlalu sedikit = ada sertifikat yang lolos. Karena phisher hampir selalu memakai sertifikat gratis Let's Encrypt, mengikuti log yang dipakai LE menangkap sebagian besar kasus. |
| Volume yang ditelan | Tiap log menyerap jutaan sertifikat per hari. Makin banyak log yang diikuti, makin besar bandwidth dan pemrosesan — untuk jumlah *match* yang sama-sama sedikit. |
| Shard mana | Log biasanya dipecah per tahun masa berlaku sertifikat. Jadi yang diikuti adalah shard tahun berjalan dan tahun berikutnya, bukan "log"-nya secara umum. |
| API mana | Targetkan **Static CT API**, bukan RFC 6962. Let's Encrypt sudah menutup log RFC 6962-nya Februari 2026, dan sebagian besar tool CT open source masih menargetkan API yang sekarat. |

### Saya tidak menyebut nama log spesifik di sini, dan itu disengaja

Daftar log yang hidup berubah terus — ada yang pensiun, ada yang baru, ada shard yang ditutup tiap tahun. Menyebut nama dari ingatan berisiko sudah basi saat Anda membacanya. Daftar resminya dipelihara Chrome dan Apple sebagai *log list*, dan itu yang harus dibaca saat menentukan.

Rekomendasi konkretnya: **mulai dari satu-dua log Static CT API yang dipakai Let's Encrypt, ukur volumenya di Blok 1, baru putuskan apakah cakupan tambahan sepadan.** Satu log dulu sudah cukup untuk membuktikan seluruh jalur kodenya benar.

Jalur cepat di dalam log: **names tiles** — JSONL berisi timestamp, CommonName, DNS SAN dan IP SAN, sehingga tidak perlu mem-parsing X.509 DER sama sekali. Untuk log yang belum menyediakannya, jalur fallback memakai data tile plus parsing DER.

04 — Probe & kondisi

## Kegagalan DNS bukan "tidak resolve"

Tiga hasil yang berbeda, tidak boleh dilebur. Kalau `SERVFAIL` diperlakukan sama dengan `NXDOMAIN`, tool ini akan mengarang transisi `registered → unregistered` setiap kali jaringan batuk — dan mengarang transisi berarti mengarang alert.

| Hasil DNS | Arti | Efek pada kondisi |
| --- | --- | --- |
| NXDOMAIN | Belum teregistrasi | `unregistered` |
| ada jawaban | Hidup | Klasifikasi lanjut |
| SERVFAIL / timeout | **Tidak diketahui** | Kondisi lama dipertahankan, error dicatat, **tidak ada transisi** |

### Lima kondisi, dan urutan prioritasnya

Classifier adalah fungsi murni: dari record DNS ke satu enum, tanpa I/O, jadi gampang dites.

| Kondisi | Kapan | Catatan |
| --- | --- | --- |
| active | Menyajikan sesuatu | **Reserved di v0.1** — butuh HTTP, tidak pernah di-set |
| certified | Muncul di CT log | Persiapan halaman phishing |
| mail_ready | Punya MX record | Paling sering dilewatkan, sering paling berbahaya |
| registered_parked | Resolve, tanpa MX | — |
| unregistered | NXDOMAIN | Aset paling berharga di sistem ini |

Urutan di tabel ini **adalah** urutan prioritasnya, dari atas ke bawah. Sebuah domain bisa punya MX *dan* sertifikat sekaligus, jadi enumnya harus memilih satu — dan karena itu fakta mentahnya tetap disimpan sebagai kolom sendiri (`has_mx`, `has_cert`), supaya verdict tidak kehilangan sinyal yang tertimpa enum.

### Transisi yang menghasilkan finding

### Lolos ke verdict

- `unregistered` → apa pun — alamat yang sudah kita tahu akan dipakai, kini hidup
- apa pun → `mail_ready` — persiapan BEC
- apa pun → `certified` — persiapan halaman phishing
- Perubahan NS atau blok IP pada domain yang sudah dipantau — sering menandai pergantian tangan
- `(none)` → `certified` — temuan CT yang saat ditemukan sudah hidup

### Tidak menghasilkan apa-apa

- Kondisi sama dengan siklus sebelumnya
- Kandidat baru yang langsung `unregistered` — itu keadaan awal, bukan peristiwa
- Probe yang gagal
- Domain yang mati lagi — dicatat di riwayat, tapi di fase 1 bukan alert. Di fase 2 ini jadi sinyal de-eskalasi.

05 — Batas modul

## Satu garis yang dijaga compiler, bukan dijaga niat baik

Garis plugin hanya nyata kalau ada yang menegakkannya. Cara paling murah: taruh tipe bersama di `internal/core` yang tidak mengimpor apa pun, lalu larang satu arah impor. Setelah itu pelanggarannya jadi error kompilasi, bukan hasil review.

**Gambar 2 — arah impor.** Aturan tambahan yang tidak digambar supaya tidak ramai: `verdict` juga tidak pernah mengimpor `probe`. Kalau verdict butuh sesuatu dari probe, yang salah adalah bentuk `DomainState`-nya, bukan aturannya.

struktur repomodule: github.com/alharitz/mirador

```
✓ = sudah ada di repo

✓ cmd/mirador/              main + CLI
✓ internal/core/            tipe bersama · TIDAK mengimpor apa pun
✓ internal/config/          config dari env var
✓ internal/source/          interface Source
  internal/source/dnstwist/  pembungkus binary dnstwist
  internal/source/ct/        Static CT API, aritmetika tile, pencocokan nama
  internal/probe/            resolver, cache, rate limit
✓ internal/api/             handler HTTP, auth token, CORS, paginasi cursor
  internal/enrich/rdap/      tanggal registrasi, hanya di atas ambang batas
✓ internal/state/           classifier, differ, Store (Postgres)
✓ internal/policy/          loader policy, scorer, penyusun what_changed
  internal/mute/
✓ internal/sink/            sink JSONL, sink webhook
  internal/runner/           orkestrasi siklus, scheduler, advisory lock
✓ migrations/   policies/   testdata/
✓ Dockerfile    compose.yaml   .env.example
```

Dua paket berganti nama saat repo dibuat: yang di dokumen ini disebut `verdict` menjadi `internal/policy/`, dan `notify` menjadi `internal/sink/`. Gambar 2 di atas masih memakai nama lama — arah impornya tidak berubah, cuma labelnya.

06 — Skema

## Tiga keputusan yang tertanam di dalamnya

Migrasi pertama, bukan skema final. Yang penting bukan kolomnya, tapi: riwayat append-only, penjadwalan per kandidat, dan finding yang idempoten.

migrations/0001_init.sqldipangkas ke yang penting

```
CREATE TYPE domain_status AS ENUM (
  'unregistered', 'registered_parked', 'mail_ready', 'certified', 'active');

CREATE TABLE candidates (
  id             bigserial PRIMARY KEY,
  fqdn           text NOT NULL UNIQUE,        -- lowercase, punycode
  brand_id       bigint NOT NULL REFERENCES brands(id),
  discovered_via text NOT NULL,               -- 'dnstwist' | 'ct'
  first_seen     timestamptz NOT NULL DEFAULT now(),
  next_check_at  timestamptz NOT NULL DEFAULT now(),   -- penjadwalan per kandidat
  tier           smallint NOT NULL DEFAULT 1);          -- 0 dingin, 1 panas
CREATE INDEX ON candidates (next_check_at);

CREATE TABLE domain_states (
  candidate_id   bigint PRIMARY KEY REFERENCES candidates(id),
  status         domain_status NOT NULL,
  has_mx         boolean NOT NULL DEFAULT false,  -- fakta mentah, terpisah dari enum
  has_cert       boolean NOT NULL DEFAULT false,
  a_records      jsonb NOT NULL DEFAULT '[]',
  mx_records     jsonb NOT NULL DEFAULT '[]',
  ns_records     jsonb NOT NULL DEFAULT '[]',
  first_live_at  timestamptz,                    -- kita saksikan sendiri kapan hidup
  registered_at  timestamptz,                    -- dari RDAP, kalau sudah ditarik
  rdap_checked_at timestamptz,                   -- null = belum pernah dicoba
  age_source     text NOT NULL DEFAULT 'unknown',  -- 'rdap'|'observed'|'unknown'
  last_checked   timestamptz NOT NULL,
  last_error     text);

-- append-only: sumber kebenaran riwayat, dan bahan mentah fase 2
CREATE TABLE state_history (
  id bigserial PRIMARY KEY,
  candidate_id bigint NOT NULL REFERENCES candidates(id),
  status domain_status NOT NULL,
  snapshot jsonb NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ON state_history (candidate_id, observed_at DESC);

CREATE TABLE findings (
  id bigserial PRIMARY KEY,
  candidate_id bigint NOT NULL REFERENCES candidates(id),
  cycle_id     bigint NOT NULL REFERENCES cycles(id),
  from_status  domain_status,                    -- NULL = baru pertama terlihat
  to_status    domain_status NOT NULL,
  score        numeric(5,2) NOT NULL,
  severity     text NOT NULL,
  policy_version int NOT NULL,               -- verdict lama tetap bisa dijelaskan
  reasoning    jsonb NOT NULL,
  what_changed text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  UNIQUE (candidate_id, cycle_id, to_status));  -- siklus diulang tidak menggandakan

CREATE TABLE mutes (
  candidate_id      bigint PRIMARY KEY REFERENCES candidates(id),
  reason            text NOT NULL,
  actor             text NOT NULL,
  muted_at_severity text NOT NULL,          -- lolos kalau severity naik
  created_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz);

CREATE TABLE ct_progress (
  log_id text PRIMARY KEY, tree_size bigint NOT NULL,
  next_index bigint NOT NULL,               -- restart melanjutkan, bukan mengulang
  updated_at timestamptz NOT NULL DEFAULT now());
```

Tabel `brands` dan `cycles` dihilangkan dari kutipan karena bentuknya biasa saja. Di migrasi sungguhan, `cycles` harus dibuat sebelum `findings` yang mereferensikannya.

### Kenapa `state_history` append-only meskipun fase 1 belum memakainya penuh

Fase 1 sebenarnya cuma butuh kondisi terakhir untuk mendeteksi transisi. Riwayat lengkapnya ditulis karena **fase 2 tidak bisa merekonstruksi masa lalu yang tidak dicatat.** Menambahkan riwayat setelah enam bulan berjalan berarti enam bulan pertama tidak punya siklus hidup yang bisa dilihat. Biayanya sekarang kecil; biaya menyesalnya nanti tidak bisa dibayar.

07 — Verdict

## Skor yang tidak bisa ditelusuri adalah bug

Bobot dan ambang batas hidup di YAML berversi. `policy_version` disimpan di setiap finding, jadi alert lama tetap bisa dijelaskan setelah bobotnya diubah.

policies/default.yamlsketsa

```
version: 1
signals:
  registered:  { weight: 10 }
  has_mx:      { weight: 30 }   # sinyal BEC
  has_cert:    { weight: 25 }   # disiapkan untuk web
  domain_age:
    weight: 35                  # mirip + baru teregistrasi = sinyal tunggal terkuat
    buckets:
      - { max_days: 7,    score: 1.0 }
      - { max_days: 30,   score: 0.7 }
      - { max_days: 180,  score: 0.3 }
      - { max_days: null, score: 0.0 }
    unknown: 0.0               # kontribusi nol, bukan tebakan

rdap:
  trigger_score: 35            # tarik RDAP hanya di atas ambang ini
  rate_per_minute: 10
  retry_after_days: 7          # kalau gagal, jangan coba tiap siklus

thresholds: { critical: 80, high: 60, medium: 35 }
```

finding · potongantiap angka menunjuk ke sinyalnya

```
{
  "reasoning": [
    { "signal": "has_mx",     "raw": "aspmx.l.google.com", "weight": 30, "contribution": 30 },
    { "signal": "registered", "raw": "185.53.178.9",       "weight": 10, "contribution": 10 },
    { "signal": "domain_age", "raw": "11 hari",             "weight": 35, "contribution": 24.5,
      "source": "rdap" }
  ],
  "what_changed": "Siklus kemarin domain ini resolve tanpa MX. Siklus ini muncul MX ke
                    Google Workspace — domain disiapkan untuk menerima email. Registry
                    mencatat domain ini didaftarkan 11 hari lalu."
}
```

`what_changed` yang membuat analis percaya, bukan skornya. Kalimat itu harus menjelaskan kenapa alert ini muncul *sekarang* dan bukan minggu lalu — dan harus jujur soal apa yang tidak diketahui.

### Severity

### Kritis

Mirip + MX aktif + sertifikat

### Tinggi

Mirip + sertifikat + baru teregistrasi

### Sedang

Mirip + teregistrasi + parkir

### Rendah

Mirip + belum teregistrasi — cukup diawasi

Aturan yang tidak dilanggar: **jangan bikin verdict berlagak lebih yakin daripada sinyalnya.** Empat sinyal itu cukup jujur untuk v0.1. Reproduksibilitas adalah properti yang *dites*, bukan yang diharapkan — input sama plus versi policy sama harus menghasilkan verdict yang identik.

08 — Umur domain

## Dua sumber, satu sinyal

"Mirip plus baru teregistrasi" adalah sinyal tunggal terkuat di seluruh sistem. Masalahnya: tanggal registrasi resmi datang dari RDAP, yang tadinya ditunda ke fase 2. Jalan tengahnya memakai dua sumber sekaligus, dengan biaya yang tetap kecil.

| Sumber | Dari mana | Cakupan & biaya |
| --- | --- | --- |
| Observasi sendiri | `first_live_at` — saat kita menyaksikan kandidat bertransisi dari `unregistered` ke hidup. | Gratis, dan presisinya sebatas irama siklus. Hanya berlaku untuk kandidat yang sudah kita pantau *sebelum* ia hidup — jadi cakupannya tumbuh sendiri seiring waktu. |
| RDAP | `registered_at` — tanggal pembuatan menurut registry. Ini definisi kanonik dari "umur domain". | Satu request HTTP ke registry per domain, ditarik **hanya untuk kandidat yang skornya sudah melewati `trigger_score`**. Volumenya kecil, jadi rate limit RDAP tidak jadi masalah. |

aturan pemilihaninternal/verdict

```
// urutan preferensi: kanonik dulu, observasi sebagai proksi, lalu menyerah
switch {
case st.RegisteredAt != nil:                // RDAP sudah ditarik
    age, src = now.Sub(*st.RegisteredAt), "rdap"

case st.FirstLiveAt != nil:                 // kita saksikan sendiri kapan hidup
    age, src = now.Sub(*st.FirstLiveAt), "observed"

default:                                   // sudah teregistrasi sebelum pemantauan dimulai
    src = "unknown"                          // kontribusi 0, dan reasoning[] mengatakannya
}
```

### Kenapa kombinasi ini tidak melanggar batas v0.1

**Ini bukan "pencocokan registrant lewat RDAP"** yang ada di daftar tidak-masuk. Yang ditarik hanya satu field: tanggal pembuatan. Pencocokan nama registrant, organisasi, dan korelasi antar-domain tetap di fase 2.

Dan penting untuk aturan OPSEC: request RDAP pergi ke **server registry**, bukan ke server penyerang. Penyerang tidak melihatnya, tidak mencatatnya, dan tidak bisa menggunakannya untuk mendeteksi kita. Aturan "fase 1 tidak pernah menyentuh infrastruktur penyerang" tetap utuh.

### Tiga hal yang bisa membuat RDAP mengecewakan

**Cakupan TLD tidak merata.** Tidak semua registry menyediakan RDAP, dan sebagian ccTLD menyembunyikan atau tidak mengisi field tanggal pembuatan. Untuk TLD seperti itu, hasilnya `unknown` — dan itu harus ditangani sebagai keadaan normal, bukan error.

**Alamat servernya harus dicari dulu.** RDAP memakai file bootstrap dari IANA yang memetakan TLD ke server RDAP-nya. File itu perlu diambil dan di-cache, dan perlu disegarkan sesekali.

**Rate limit tiap registry berbeda dan sebagian tidak didokumentasikan.** Saya tidak tahu angka pastinya per registry dan tidak mau menebak. Karena itu `rate_per_minute` ada di policy sebagai angka yang bisa diturunkan, dan kegagalan RDAP tidak boleh menggagalkan siklus — cukup dicatat dan dicoba lagi setelah `retry_after_days`.

Tanggal registrasi tidak berubah, jadi hasil RDAP di-cache permanen: satu domain ditarik sekali seumur hidupnya. `rdap_checked_at` yang null berarti belum pernah dicoba; yang terisi tapi `registered_at` kosong berarti sudah dicoba dan registry tidak memberi jawaban.

09 — Mute

## Blok terpendek, dan yang menentukan tool ini dipakai atau dimatikan

Analis akan menandai sesuatu sebagai bukan ancaman: registrasi defensif perusahaan sendiri, domain partner, false positive yang jelas. Kalau tool-nya lupa dan mengalert ulang hal yang sama tiap siklus, **tool itu akan dimatikan dalam dua minggu.**

| Aturan | Kenapa begitu |
| --- | --- |
| Mute diterapkan setelah verdict, bukan sebelum | Aturannya butuh severity. Domain ter-mute tetap dipantau dan tetap dihitung skornya. |
| Lolos kalau severity naik | Domain partner yang tiba-tiba menyajikan halaman login tiruan tetap harus lewat. Karena itu `muted_at_severity` disimpan di baris mute. |
| Impor massal aset sendiri | Perusahaan besar punya ratusan registrasi defensif. Tanpa ini, siklus pertama menghasilkan ratusan alert dan tidak ada siklus kedua. |

Di fase 2, tabel `mutes` ini yang tumbuh jadi `dispositions` — "aman" berubah dari sekadar penyaring alert menjadi keputusan analis yang punya riwayat dan bisa dibatalkan. Bentuk kolomnya sengaja sudah mengarah ke sana.

10 — API & CLI

## Kontraknya adalah produknya

Fase 1 menghasilkan engine **plus HTTP API**. Frontend adalah aplikasi terpisah di fase 2, dan selama pengembangan API-nya dipakai lewat Postman. Konsekuensinya: kontrak JSON ini adalah artefak yang paling mahal untuk diubah, jadi ia dirancang sebelum handler pertamanya ditulis.

HTTP API v1sketsa · OpenAPI menyusul

```
GET  /v1/health                    status database, siklus terakhir, versi build
GET  /v1/findings                  ?since= &severity= &brand= &cursor= &limit=
GET  /v1/findings/{id}             reasoning[] dan what_changed lengkap
GET  /v1/candidates                ?brand= &status= &cursor=
GET  /v1/candidates/{fqdn}         kondisi sekarang + riwayat transisinya
GET  /v1/brands
POST /v1/brands                    {"domain": "example.com"}

Auth : header Authorization dengan satu token statis dari env var.
       Bukan akun pengguna — multi-user itu fase 3.
CORS : diaktifkan, karena frontend nanti beda origin.
```

Pagination-nya berbasis **cursor, bukan offset**. Findings itu tabel yang terus tumbuh dan disisipi dari kepala; `OFFSET` pada tabel seperti itu melewatkan dan menggandakan baris begitu ada data baru masuk di tengah paginasi.

### Kenapa API dan worker bisa dipisah tanpa biaya

Seluruh state ada di Postgres. Jadi proses yang melayani HTTP dan proses yang menjalankan siklus **tidak perlu saling bicara sama sekali** — keduanya cuma bicara ke database. Tidak ada antrian, tidak ada RPC internal, tidak ada shared memory yang harus diurus.

Bentuknya di v0.1: satu binary, dua subperintah — `mirador serve` dan `mirador run` — dari satu image yang sama, dijalankan sebagai dua service di compose. Kalau nanti perlu discale, API-nya bisa diperbanyak tanpa menyentuh worker, dan worker tetap aman karena `run` memegang advisory lock Postgres.

### CLI — tetap ada, untuk operasional

Yang lewat CLI adalah perintah operator, bukan fitur pengguna: hal-hal yang dijalankan sekali atau dijadwalkan, bukan yang dibuka tiap hari.

docker compose run --rm app mirador ...operasional

```
mirador migrate                        jalankan migrasi database
mirador serve                          daemon: HTTP API
mirador run                            daemon: scheduler + CT follower
mirador generate --brand example.com   jalankan dnstwist, isi kandidat
mirador cycle --once                   satu siklus probe, untuk debugging
mirador mute <domain> --reason "..."   mute / unmute
mirador mute import assets.txt         impor massal aset sendiri
mirador policy validate policies/x.yaml
```

`mirador findings` dibuang dari CLI: begitu ada `GET /v1/findings`, dua jalan baca untuk data yang sama cuma jadi dua tempat yang harus dijaga tetap sama.

11 — Daftar fitur

## Dua puluh dua fungsional, tujuh non-fungsional

| # | Fitur | Catatan |
| --- | --- | --- |
| F1 | Daftar brand yang dijaga | CLI `brand add`, tabel `brands` |
| F2 | Generate kandidat via dnstwist | Dipanggil sebagai binary di dalam container, tidak ditulis ulang |
| F3 | Normalisasi & dedup kandidat | lowercase, punycode, strip wildcard, unique per FQDN |
| F4 | Resolve A, MX, NS | Konkurensi terbatas, rate limit, cache TTL di Postgres |
| F5 | Klasifikasi kondisi | Lima status; `active` reserved |
| F6 | Simpan kondisi + riwayat | `domain_states` + `state_history` append-only |
| F7 | Deteksi transisi | Hanya transisi bermakna yang lolos ke verdict |
| F8 | Verdict dari policy YAML | Empat sinyal, bobot dan ambang batas berversi |
| F9 | `reasoning[]` dan `what_changed` | Ini yang membuat analis percaya, bukan skornya |
| F10 | Pemetaan severity | Empat level |
| F11 | Mute & acknowledge | Lolos kalau severity naik dibanding saat di-mute |
| F12 | Impor massal aset sendiri | Tanpa ini siklus pertama membanjir |
| F13 | Keluaran JSONL | Append-only, satu finding per baris, format stabil |
| F14 | Webhook | Retry + backoff; kegagalan kirim tidak menggagalkan siklus |
| F15 | Sumber CT log | Static CT API, names tiles, posisi tersimpan |
| F16 | Pencocokan nama CT ke brand | Normalisasi, edit distance per label, homoglyph, pola brand+kata kunci |
| F17 | Penjadwalan bertingkat | `next_check_at` per kandidat, tier panas/dingin |
| F18 | CLI operasional | migrate, serve, run, generate, cycle, mute, policy validate |
| F19 | Umur domain: observasi + RDAP terbatas | Hanya tanggal registrasi, hanya di atas ambang batas — bagian 08 |
| F20 | HTTP API v1 | findings, candidates, brands, health — paginasi berbasis cursor |
| F21 | OpenAPI spec | Koleksi Postman digenerate dari sini, dan nanti jadi tipe untuk frontend |
| F22 | Auth token + CORS | Satu token statis dari env var. Akun pengguna itu fase 3. |

| # | Properti | Bentuk konkretnya |
| --- | --- | --- |
| N1 | Idempoten | Siklus yang diulang tidak menggandakan finding — dijaga `UNIQUE` di tabel |
| N2 | Resumable | CT melanjutkan dari `next_index`; siklus dari `next_check_at` |
| N3 | Reproducible | Input sama + `policy_version` sama = verdict identik. Punya test sendiri. |
| N4 | Tahan gagal | SERVFAIL ≠ NXDOMAIN. RDAP gagal ≠ siklus gagal. Tidak pernah mengarang transisi. |
| N5 | Teramati | Per siklus: kandidat diproses, lookup/detik, error rate, durasi |
| N6 | Sopan | Rate limit ke resolver, ke log CT, dan ke registry RDAP |
| N7 | Aman dikerjakan sendirian | Tidak pernah menyentuh infrastruktur penyerang — hanya resolver, log publik, dan registry |

12 — Belum diputus

## Empat hal yang tersisa

Yang lain sudah dikunci: nama proyek, stack, kemasan container, status `active`, penanganan umur domain, dan batas backend-dulu. Sisanya butuh angka yang belum ada.

### Log CT mana yang di-tail

Operator dan shard-nya. Baca log list Chrome/Apple saat menentukan, mulai dari satu-dua log Static CT API yang dipakai Let's Encrypt, lalu ukur volumenya. Lihat bagian 03.

### Angka `trigger_score` untuk RDAP

Sketsa di bagian 07 memakai 35, sama dengan ambang `medium`. Angka itu belum diuji — kalau terlalu rendah, volume RDAP membengkak; kalau terlalu tinggi, sinyal umur jarang terisi.

### Irama siklus yang sebenarnya

Angka 6 / 24 jam di Gambar 1 adalah tebakan. Blok 1 yang menentukannya, setelah volume kandidat dan waktu resolve yang nyata diukur.

### Platform cloud

Egress DNS sudah dikonfirmasi jalan dari lingkungan development, tapi lingkungan dev bukan PaaS. Uji dengan mengirim beberapa ribu query dari platform kandidat sebelum memilihnya.

### Rujukan teknis

- [dnstwist](https://github.com/elceef/dnstwist) — Apache-2.0, fondasi permutasi
- [Static CT API v1.1.0](https://c2sp.org/static-ct-api@v1.1.0) — format tile, checkpoint, path
- [Names tiles](https://github.com/FiloSottile/sunlight/blob/main/names-tiles.md) — JSONL berisi CN dan SAN, tanpa parsing DER
- [filippo.io/sunlight](https://pkg.go.dev/filippo.io/sunlight) — klien Static CT API dalam Go (referensi lama; tumpukan saat ini menggunakan Rust)
- [Let's Encrypt: RFC 6962 logs EOL](https://letsencrypt.org/2025/08/14/rfc-6962-logs-eol) — alasan menargetkan Static CT API
- [certificate-transparency-go](https://github.com/google/certificate-transparency-go) — parsing X.509 untuk jalur fallback

Dokumen 02 dari seri Mirador. Konteks produk dan peta fase ada di dokumen 01; blok kerja dan kriteria selesai per blok ada di dokumen 03. Angka volume, irama siklus, rate limit RDAP, dan perilaku egress DNS di platform cloud belum diukur — semuanya ditandai sebagai tebakan di tempatnya masing-masing.