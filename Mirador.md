Dokumen 01/ 8 September 2026/ Status: pra-kode/ AGPL-3.0

# Mirador

**M**onitoring **I**mpostor **R**egistrations **A**nd **D**omain **O**wnership **R**ecords

dnstwist memberi tahu domain mirip apa yang ada. Ini memberi tahu **kapan salah satunya mulai bergerak**, dan nanti, **kapan salah satunya berhenti berbahaya.**

Rust + postgresql containerized self-hosted atau cloud agpl-3.0

[01 Masalah](#masalah) [02 Celahnya](#celah) [03 Dua pembeda](#pembeda) [04 Model kondisi](#kondisi) [05 Arsitektur](#arsitektur) [06 Deployment](#deploy) [07 Peta fase](#fase) [08 Siklus hidup](#siklus) [09 Stack](#stack) [10 Keputusan](#keputusan) [11 Risiko](#risiko) [12 Prinsip](#prinsip)

Dokumen umum. Batas dan detail teknis v0.1 ada di dokumen 02; checklist kerjanya di dokumen 03.

01 — Masalah

## Yang berbahaya bukan keberadaannya

Setiap organisasi punya domain mirip yang bisa dipakai menyerangnya — typo, homoglyph, brand plus kata kunci. Sebagian sudah teregistrasi dan parkir. Sebagian belum teregistrasi sama sekali.

Domain mirip yang parkir lima tahun bukan berita. Yang berbahaya adalah **saat salah satunya mulai disiapkan**: dapat MX record, dapat sertifikat, mulai menyajikan halaman login tiruan.

Cara kerja tim keamanan hari ini: menjalankan dnstwist sesekali, membaca outputnya, lalu melupakannya sampai ada insiden. Tidak ada yang menyimpan kondisi sebelumnya — jadi tidak ada yang tahu **apa yang berubah**.

02 — Celahnya

## Apa yang sudah ada, dan apa yang tidak

### dnstwist

- 5,7rb bintang, Apache-2.0, aktif dipelihara. Algoritma permutasinya bagus dan lisensinya permisif — boleh dipakai sebagai fondasi.
- Sudah melakukan: permutasi (homoglyph, hyphenation, IDN, dictionary), cek DNS dan MX, kemiripan HTML dan visual, GeoIP, ekspor CSV/JSON.
- **Batasnya:** scan sekali jalan. Tidak menyimpan kondisi, tidak membandingkan antar waktu, tidak memberi alert.

### Lapis komersial

- CTM360, Group-IB, Bolster dan lainnya menjual brand protection dengan pemantauan berkelanjutan plus layanan takedown.
- Mahal, SaaS murni, dan verdict-nya kotak hitam.
- Bersaing di jumlah sumber melawan mereka adalah pertarungan modal, bukan pertarungan rekayasa. Bukan medan yang tepat untuk side project.

### Celah yang nyata

Tidak ada yang **open source, self-hosted, memantau terus-menerus, dan verdict-nya bisa diperiksa.** Itu ruang yang ditempati proyek ini — dan satu-satunya ruang yang ditempatinya.

03 — Dua pembeda

## Dan hanya dua

Kalau salah satu dari dua ini dibuang, yang tersisa cuma pembungkus dnstwist. Setiap fitur yang tidak melayani salah satunya, ditunda — di fase mana pun.

### 1. Deteksi perubahan

- Kondisi tiap domain disimpan. Tiap siklus dibandingkan dengan kondisi sebelumnya.
- Yang keluar adalah **transisinya**, bukan daftarnya.
- Konsekuensi: domain yang belum teregistrasi harus disimpan sejak sebelum hidup — itu aset paling berharga di sistem ini.

### 2. Verdict yang bisa dijelaskan

- Skor datang dari policy YAML berversi, bukan dari kode.
- Setiap angka bisa ditelusuri ke sinyal pembentuknya.
- Analis bisa membantahnya, dan auditor bisa dijawab tanpa membuka kode.

04 — Model kondisi

## Alert lahir dari perpindahan, bukan dari keadaan

Ini jantung produknya, dan bentuk data yang menentukan semua fase berikutnya.

memicu alert dicatat, tidak memicu butuh HTTP · fase 2

**Gambar 1 — mesin kondisi.** Tiga panah bersinyal adalah seluruh alasan tool ini ada. Domain yang parkir sejak dulu dan masih parkir tidak pernah menyentuh verdict engine sama sekali — itu yang membuatnya tidak berisik.

### Kenapa `active` butuh HTTP, dan kenapa itu ditunda

Empat kondisi pertama dideteksi **tanpa menyentuh penyerang**: DNS lookup ditanyakan ke resolver, dan CT log memang publik. Penyerang tidak tahu kita ada.

`active` berbeda jenis. "Menyajikan halaman login tiruan" hanya bisa diketahui dengan **membuka website-nya** — mengirim request HTTP ke server penyerang. Begitu itu terjadi: IP kita masuk access log mereka; phisher yang rapi memantau scanner dan bisa memblokir kita atau pindah; dan situs phishing modern melakukan *cloaking* — halaman bersih untuk IP yang dicurigai scanner, halaman asli untuk korban.

Karena itu fase 1 sengaja tidak pernah menyentuh infrastruktur penyerang. Kolom enumnya tetap disiapkan sekarang supaya tidak perlu migrasi tipe di Postgres nanti, tapi nilainya tidak pernah di-set sampai HTTP prober masuk di fase 2 — saat deployment sudah di cloud dan IP yang terpapar bukan IP rumah.

05 — Arsitektur

## Dua sumber, satu pintu masuk, satu pipeline hilir

Permutasi menebak lalu memverifikasi (*push*); CT mengamati semua lalu menyaring (*pull*). Keduanya menutupi lubang yang berbeda, dan keduanya masuk lewat interface yang sama supaya hilirnya tidak pernah tahu asal-usul kandidat.

| Sumber | Cara kerja | Menangkap |
| --- | --- | --- |
| Permutasi | Tebak lalu verifikasi (*push*) | Domain tanpa sertifikat — parkir, atau khusus email |
| CT log | Amati semua lalu saring (*pull*) | Nama yang tidak akan pernah ditebak, dalam hitungan menit setelah sertifikat terbit |

Permutasi melewatkan `masuk-akun-bca.id` dan `secure-login-verify.tk` — pola brand plus kata kunci, yang justru paling sering dipakai penipu sungguhan. CT menangkapnya. Sebaliknya CT melewatkan domain yang tidak pernah minta sertifikat. Permutasi menangkapnya.

**Gambar 2 — aliran data.** Perhatikan urutannya: verdict ada *setelah* differ, bukan sebelumnya — skor dihitung untuk transisi, bukan untuk domain. Dan mute diterapkan *setelah* verdict, karena aturannya butuh severity: domain partner yang tiba-tiba menyajikan halaman login tiruan tetap harus lewat.

Bentuk ini yang membuat fase 2 bersifat **menambah, bukan membongkar**. HTTP prober masuk sebagai satu komponen baru di siklus probe; standing verdict masuk sebagai satu tabel baru di Postgres. Tidak ada yang perlu ditulis ulang.

06 — Deployment

## Satu image, tiga tempat

Containerized sejak hari pertama — termasuk untuk development. Ini bukan keputusan estetika: ia menyelesaikan tiga masalah sekaligus, dan salah satunya adalah masalah yang sempat jadi ganjalan arsitektur.

**Gambar 3 — topologi deployment.** Image yang sama dipakai di ketiganya; yang berbeda hanya env var dan asal Postgres-nya. Tidak ada build khusus per lingkungan, jadi "jalan di laptop saya" berhenti jadi kalimat yang masuk akal.

### Tiga masalah yang diselesaikan sekaligus

| Masalah | Bagaimana container menyelesaikannya |
| --- | --- |
| dnstwist itu Python | Ini sempat jadi ganjalan: Rust dipilih untuk konkurensi dan keselamatan memori; memanggil dnstwist sebagai binary Python eksternal tidak mengganggu unit distribusi container. Dengan container, **unit distribusinya adalah image, bukan file** — jadi Rust + Python dalam satu image sama sekali bukan masalah. Ganjalannya hilang, bukan dikompromikan. Batas fase 1 tetap pasif: tidak ada HTTP ke domain kandidat. |
| Postgres di laptop | Tidak perlu memasang Postgres di mesin development. `docker compose up` memberi database bersih, dan `down -v` mengembalikannya ke nol saat skema berubah. |
| Cloud atau self-hosted | Keduanya jalan dari image yang sama. Pengguna self-hosted menjalankan `docker compose up`; versi cloud men-deploy image yang sama ke PaaS dengan Postgres terkelola. |

compose.yaml · developmentsketsa

```
services:
  app:
    build: .
    env_file: .env
    volumes:
      - .:/src                      # kode di-mount, rebuild cepat
      - ./out:/var/lib/mirador  # JSONL keluar ke sini
    depends_on: [db]

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: mirador
    volumes: [pgdata:/var/lib/postgresql/data]

volumes: { pgdata: {} }
```

Satu-satunya state di luar Postgres adalah file JSONL. Itu disengaja: kalau container hilang, yang hilang cuma salinan — kebenaran ada di database.

### Yang masih harus diverifikasi sebelum memilih platform cloud

Beban kerjanya puluhan ribu query DNS UDP per siklus dari dalam container. Dari lingkungan development, egress DNS sudah dikonfirmasi jalan. **Tapi lingkungan dev bukan PaaS.** Sebagian platform membatasi atau memproksi egress UDP, dan sebagian resolver publik akan me-rate-limit sumber dengan volume seperti ini.

Saya tidak yakin bagaimana perilaku persisnya di masing-masing platform dan tidak mau menebak — ini harus diuji langsung dengan mengirim beberapa ribu query dari platform kandidat. Jalur cadangan kalau UDP bermasalah: DNS over TCP, atau DoH ke resolver yang mengizinkan volume ini. Keduanya lebih lambat dan lebih mahal per query, jadi lebih baik tahu sebelum arsitekturnya mengeras.

07 — Peta fase

## Tiga fase, tanpa tanggal

Kapasitasnya "ngisi waktu kosong". Rencana berbasis tanggal akan lewat, lalu rasa bersalahnya yang membunuh proyek. Jadi: berbasis fase, dan tiap fase berdiri sendiri.

**Gambar 4 — peta fase.** Tidak ada tanggal di sini, dan itu disengaja. Yang ada adalah urutan: fase 2 tidak bisa dikerjakan sebelum fase 1 menyimpan riwayat, dan fase 3 tidak ada gunanya sebelum Anda sendiri memakai hasilnya.

08 — Siklus hidup

## Verdict yang bisa berbalik arah

Niat awal proyek ini bukan cuma "ada domain mencurigakan", tapi **memantau keadaannya terus** — termasuk saat sesuatu yang berbahaya berhenti berbahaya, atau sesuatu yang aman berubah jadi berbahaya. Itu fase 2, dan ini bentuknya.

eskalasi — jadi lebih berbahaya de-eskalasi — berhenti berbahaya

**Gambar 5 — siklus hidup verdict (fase 2).** Yang membedakan ini dari Gambar 1: Gambar 1 melacak *fakta* yang berubah (ada MX, ada sertifikat), Gambar 5 melacak *penilaian* yang berubah — dan penilaian bisa turun, bukan cuma naik.

### Dua arah pembalikan, dan apa yang menyebabkannya

| Arah | Penyebab nyata di lapangan | Sinyal yang menandainya |
| --- | --- | --- |
| Berbahaya → aman | Domain di-takedown registrar; hosting-nya disuspend; penyerang pindah dan meninggalkannya; brand owner membelinya sebagai registrasi defensif. | MX dihapus, sertifikat kedaluwarsa dan tidak diperpanjang, halaman phishing hilang, NS berpindah ke registrar parkir, domain berhenti resolve. |
| Aman → berbahaya | Domain partner atau domain lama kedaluwarsa lalu ditangkap orang lain (*drop-catch*); situs sah dikompromikan; registrasi defensif yang lupa diperpanjang. | NS dan blok IP berpindah, sertifikat baru dari CA yang berbeda, MX baru, konten berubah total. |

### Kenapa ini fase 2, bukan fase 1

Bukan karena datanya belum ada — justru sebaliknya. Fase 1 sudah menyimpan `state_history` yang append-only dan seluruh `findings`-nya, jadi bahan mentah untuk merekonstruksi siklus hidup sudah lengkap sejak hari pertama. Yang belum ada adalah dua hal yang *harus* menunggu: **bukti HTTP** (tanpa membuka situsnya, "masih menyajikan halaman palsu atau tidak" tidak bisa dijawab) dan **keputusan analis** (yang butuh antarmuka untuk mencatatnya). Keduanya masuk di fase 2 sekaligus, dan tabel `dispositions` tinggal ditambahkan — skema fase 1 tidak perlu diubah.

09 — Stack

## Yang dipakai, dan kenapa yang itu

| Lapisan | Pilihan | Alasan |
| --- | --- | --- |
| Bahasa | Rust | Model konkurensinya pas untuk puluhan ribu lookup paralel; ekosistem DNS dan CT-nya matang; keselamatan memori menghindari kelas bug tertentu. |
| Database | PostgreSQL | Lihat bagian 10. |
| Kemasan | Container | Unit distribusi di dev, cloud, dan self-hosted. Lihat bagian 06. |
| DNS | miekg/dns | Kontrol penuh atas tipe query, timeout, dan pemilihan resolver — `net.Resolver` bawaan tidak memberi itu. |
| CT | filippo.io/sunlight | Klien Static CT API. Jalur cepatnya *names tiles*: JSONL berisi CN dan SAN, tanpa parsing X.509 DER sama sekali. |
| Permutasi | dnstwist (Apache-2.0, versi yang dipin) | Dipanggil sebagai binary Python eksternal, tidak ditulis ulang. |
| Driver | jackc/pgx v5 | Dukungan `jsonb`, enum, dan tipe Postgres yang rapi. |
| Policy | gopkg.in/yaml.v3 | Policy yang salah harus gagal saat dimuat, bukan saat dipakai. (digantikan oleh serde_yaml dalam implementasi Rust) |
| Log & metrik | log/slog + tabel cycles | JSON terstruktur tanpa dependensi. Tanpa metrik siklus, loop yang macet diam-diam tidak akan ketahuan. |

*Catatan: Referensi library Go dalam tabel di atas (miekg/dns, filippo.io/sunlight, jackc/pgx v5, gopkg.in/yaml.v3) diganti dengan ekuivalen Rust dalam implementasi Rust Mirador. Lihat catatan khusus untuk gopkg.in/yaml.v3 di baris 186.
Daftar lengkap termasuk migrasi, CLI, dan library konkurensi ada di dokumen 02.

10 — Keputusan

## Yang sudah dikunci, dan alasannya

Ditulis supaya tidak jadi keputusan diam-diam yang membingungkan diri sendiri tiga bulan lagi.

| Keputusan | Alasan |
| --- | --- |
| Nama: Mirador | *Monitoring Impostor Registrations And Domain Ownership Records.* Bahasa Spanyol: menara pandang — tempat berdiri untuk melihat pergerakan di lembah sebelum sampai ke gerbang. Modul dan binary-nya `mirador`. **Masih harus dicek bentroknya** di pkg.go.dev dan GitHub sebelum repo dibuat publik: pencarian web menemukan satu image viewer IIIF bernama sama, bidang yang berbeda, tapi itu bukan pengecekan yang otoritatif. |
| Rust | Konkurensi untuk puluhan ribu lookup paralel; kesalahan memori dikoreksi pada waktu kompilasi; ekosistem DNS dan CT-nya matang. Argumen "binary tunggal" sudah tidak relevan sejak kemasannya container — tapi alasan konkurensinya tetap berdiri sendiri. |
| PostgreSQL, bukan SQLite | Target deployment cloud tanpa server sendiri. Di PaaS, filesystem container umumnya ephemeral — SQLite di sana berarti database yang hilang saat redeploy, dan untuk tool yang *seluruh nilainya adalah riwayat*, itu kegagalan senyap yang fatal. Ditambah advisory lock, `jsonb`, dan enum asli yang semuanya terpakai langsung. Mitigasi: penyimpanan di belakang `interface Store` sejak baris pertama, jadi implementasi SQLite nanti cuma satu file baru. |
| Containerized sejak dev | Menyelesaikan ganjalan dnstwist-Python, menghilangkan Postgres dari laptop, dan membuat cloud dan self-hosted berjalan dari image yang sama. Lihat bagian 06. |
| Backend dulu, frontend menyusul | Fase 1 menghasilkan **engine plus HTTP API**; frontend adalah aplikasi terpisah di fase 2. Selama pengembangan, API-nya dipakai lewat Postman. Yang membuat pemisahan ini murah: seluruh state ada di Postgres, jadi proses API dan proses worker *tidak perlu saling bicara sama sekali* — keduanya cuma bicara ke database. Konsekuensinya kontrak JSON-nya jadi artefak kelas satu: ia harus dirancang sebelum handler ditulis, karena mengubahnya setelah frontend jadi itu mahal. |
| Umur domain: observasi + RDAP terbatas | Sumber utama `first_live_at` dari observasi sendiri; RDAP ditarik hanya untuk kandidat yang sudah melewati ambang batas. Rinciannya di dokumen 02. Penting: RDAP adalah request ke *registry*, bukan ke server penyerang — jadi ini tidak melanggar aturan "jangan sentuh infrastruktur penyerang". |
| AGPL-3.0 | Bebas dipakai, tertutup untuk di-SaaS-kan diam-diam. Lisensi komersial tetap terbuka sebagai jalur monetisasi di fase 3. Pasang `LICENSE` sebelum baris kode pertama — menambahkan copyleft ke kode yang sudah dikontribusikan orang lain jauh lebih ribet. |

11 — Risiko

## Yang paling mungkin membunuh proyek ini

Diurutkan dari yang paling mungkin terjadi — dan yang teratas bukan masalah teknis.

| Risiko | Kenapa nyata | Mitigasi |
| --- | --- | --- |
| Motivasi habis | Side project waktu kosong paling sering mati saat kerjaan sudah tidak baru lagi tapi hasilnya belum kelihatan. | Blok kecil yang tiap satunya berdiri sendiri. Titik berhenti terhormat setelah Blok 4. Tidak ada tanggal. |
| Banjir false positive | Registrasi defensif dan domain partner terlihat persis seperti ancaman. Tanpa penanganan, siklus pertama menghasilkan ratusan alert. | Baseline aset sendiri plus mute — dua-duanya wajib di fase 1, bukan fitur pinggiran. |
| Ruang permutasi meledak | Satu brand di semua TLD itu ribuan sampai puluhan ribu kandidat, bukan ratusan. | Anggaran per siklus. Prioritaskan TLD dan pola yang relevan. Jangan generate-semua. |
| Volume DNS | Puluhan ribu lookup per siklus, dan resolver publik akan me-rate-limit. | Cache, rate limit, penjadwalan bertingkat. Ini kerja teknis nyata, bukan detail implementasi. |
| dnstwist berubah arah | Ketergantungan pada proyek orang lain. | Apache-2.0, dan `interface Source` membuat sumber CT tetap jalan tanpa dnstwist sama sekali. |

12 — Prinsip

## Empat aturan yang menjaga proyek ini tetap hidup

### Cara memutuskan

- **Bangun untuk diri sendiri dulu.** Pengguna nomor satu adalah Anda. Pertanyaan pasar ditunda sampai barangnya ada.
- **Dua pembeda, tidak lebih.** Fitur yang tidak melayani deteksi perubahan atau verdict yang bisa dijelaskan, ditunda — di fase mana pun.

### Cara membangun

- **Yang disimpan kondisi, yang dikirim transisi.** Ini yang membuat fase 2 jadi penambahan, bukan pembongkaran.
- **Berhenti di titik terhormat itu boleh.** Setelah Blok 4 proyeknya sudah berguna dan sudah bisa dipublish. Rencana tanpa titik berhenti terhormat adalah rencana yang akan ditinggalkan diam-diam.

### Dokumen berikutnya

**02 — Mirador v0.1** berisi batas, komponen, skema Postgres, policy, dan daftar fitur fase 1 secara lengkap. **03 — Task List v0.1** berisi blok kerjanya dengan kriteria selesai per blok. Dokumen ini tidak perlu dibuka lagi kecuali ada asumsi yang patah.

### Rujukan teknis

- [dnstwist](https://github.com/elceef/dnstwist) — Apache-2.0, fondasi permutasi
- [Static CT API v1.1.0](https://c2sp.org/static-ct-api@v1.1.0) — format tile, checkpoint, path
- [Names tiles](https://github.com/FiloSottile/sunlight/blob/main/names-tiles.md) — JSONL berisi CN dan SAN, tanpa parsing DER
- [filippo.io/sunlight](https://pkg.go.dev/filippo.io/sunlight) — klien Static CT API dalam Go (referensi lama; tumpukan saat ini menggunakan Rust)
- [Let's Encrypt: RFC 6962 logs EOL](https://letsencrypt.org/2025/08/14/rfc-6962-logs-eol) — alasan menargetkan Static CT API
- [certificate-transparency-go](https://github.com/google/certificate-transparency-go) — parsing X.509 untuk jalur fallback

Dokumen 01 dari seri Mirador, menggantikan Charter versi sebelumnya. Angka volume, irama siklus, dan perilaku egress DNS di platform cloud belum diukur — semuanya ditandai sebagai tebakan di tempatnya masing-masing, dan Blok 1 yang menggantinya dengan angka nyata.