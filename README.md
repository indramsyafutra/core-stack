# note:

docker run --rm --name test-apisix apache/apisix:3.8.0-debian \
cat /usr/local/apisix/conf/config-default.yaml


cd /home/vm-67-portainer/core-stack
chmod +x apisix/init-apisix.sh

# pertama kali (atau setelah reset APISIX):
docker compose up -d
./apisix/init-apisix.sh

cd /home/vm-67-portainer/core-stack
set -a
. .env
set +a

# sekarang variabel:
#   $AK
#   $APISIX_ADMIN_URL
#   $SSO_HOST
#   $OPS_HOST
#   dsb
# sudah available di shell

curl -s -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/routes" | jq .


# core-stack: APISIX + Keycloak SSO (sso.example.com)

Stack ini berisi reverse proxy **Apache APISIX**, **Keycloak** sebagai SSO, **PostgreSQL** sebagai database Keycloak, **etcd** untuk APISIX, dan **Portainer** untuk manajemen Docker.

Dokumen ini menjelaskan **konfigurasi dari nol** setelah:


docker compose down -v
# lalu
docker compose up -d
Artinya: semua data APISIX (etcd) dan Keycloak (Postgres) kosong lagi.

1. Prasyarat
Sudah install:

Docker

docker compose

DNS sso.example.com sudah mengarah ke IP server ini.

Sertifikat SSL wildcard sudah terpasang di host:



/etc/ssl/example/fullchain.crt
/etc/ssl/example/private.key
(Stack sudah meng-mount folder ini ke container APISIX.)

2. Clone repo & masuk folder


git clone https://github.com/indramsyafutra/core-stack.git
cd core-stack
3. Siapkan file .env
Buat file .env di root core-stack (sesuaikan nilai untuk lab/prod):



cat > .env << 'EOF'
# ====== Postgres / Keycloak DB ======
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=changeme_db_password

KC_DB_NAME=keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=changeme_db_password  # harus sama dengan POSTGRES_PASSWORD

# ====== Keycloak ======
KEYCLOAK_VERSION=26.0.5
KC_ADMIN=admin
KC_ADMIN_PASSWORD=changeme_admin_password

# Hostname untuk SSO
SSO_HOST=sso.example.com

# ====== APISIX admin API key ======
# Sesuaikan dengan admin_key pada apisix/conf/config.yaml
APISIX_ADMIN_API_KEY=edd1c9f034335f136f87ad84b625c8f1

EOF
Catatan:
Untuk production beneran, ubah semua password & key ini ke nilai yang kuat.

4. Start stack
Dari folder core-stack:



docker compose down -v
docker compose up -d
Cek container:



docker ps --format 'table {{.Names}}\t{{.Status}}'
Harus muncul minimal:

core-stack-etcd

core-stack-apisix

core-stack-postgres

core-stack-keycloak

core-stack-portainer

Tunggu sampai:

Postgres statusnya Up

Keycloak: di logs muncul Listening on: http://0.0.0.0:8080

APISIX: tidak ada error fatal di logs

Cek cepat:



docker logs --tail=20 core-stack-keycloak
docker logs --tail=20 core-stack-apisix
5. Siapkan akses ke APISIX admin API
Admin API hanya bisa diakses dari host (127.0.0.1) dengan header X-API-KEY.

Load .env dan set variabel AK:



cd ~/core-stack
set -a
source .env
set +a

export AK="$APISIX_ADMIN_API_KEY"
Tes koneksi admin API:



curl -i -H "X-API-KEY: $AK" http://127.0.0.1:9180/apisix/admin/routes
Kalau berhasil, akan balas 200 OK dengan JSON:

json

{"list":[],"total":0}
Artinya: APISIX jalan, tapi belum ada route.

6. Konfigurasi upstream Keycloak di APISIX
Kita buat upstream up_sso yang menunjuk ke container keycloak:8080 (pakai internal Docker network core-net).



cat > /tmp/upstream_sso.json << 'EOF'
{
  "id": "up_sso",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": {
    "keycloak:8080": 1
  },
  "pass_host": "pass"
}
EOF

curl -i -X PUT "http://127.0.0.1:9180/apisix/admin/upstreams/up_sso" \
  -H "X-API-KEY: $AK" \
  -H "Content-Type: application/json" \
  -d @/tmp/upstream_sso.json

# Verifikasi:

curl -s -H "X-API-KEY: $AK" \
  http://127.0.0.1:9180/apisix/admin/upstreams/up_sso \
  | jq '.value'

# Harus tampil node keycloak:8080.

7. Konfigurasi route sso.example.com → Keycloak
Buat route route_sso untuk host sso.example.com yang meneruskan semua path /* ke upstream up_sso.
Tambahkan header X-Forwarded-* supaya Keycloak paham bahwa dia diakses lewat HTTPS di port 443.



cat > /tmp/route_sso.json << 'EOF'
{
  "id": "route_sso",
  "uri": "/*",
  "hosts": [
    "sso.example.com"
  ],
  "priority": 10,
  "upstream_id": "up_sso",
  "plugins": {
    "proxy-rewrite": {
      "headers": {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": "$host",
        "X-Forwarded-Port": "443"
      }
    }
  }
}
EOF

curl -i -X PUT "http://127.0.0.1:9180/apisix/admin/routes/route_sso" \
  -H "X-API-KEY: $AK" \
  -H "Content-Type: application/json" \
  -d @/tmp/route_sso.json


# Cek lagi:

curl -s -H "X-API-KEY: $AK" \
  http://127.0.0.1:9180/apisix/admin/routes/route_sso \
  | jq '.value | {id, uri, hosts, upstream_id, plugins}'


jq -n \
  --rawfile crt /etc/ssl/example/fullchain.crt \
  --rawfile key /etc/ssl/example/private.key \
  '{
    id:   "ssl_example",
    cert: $crt,
    key:  $key,
    snis: [
      "sso.example.ac.id",
      "*.example.ac.id",
      "example.ac.id"
    ]
  }' > /tmp/ssl-example.json


curl -i -X PUT "http://127.0.0.1:9180/apisix/admin/ssls/ssl_example" \
  -H "X-API-KEY: $AK" \
  -H "Content-Type: application/json" \
  -d @/tmp/ssl-example.json

# VERIFIKASI SSL OBJECT
curl -s -H "X-API-KEY: $AK" \
  http://127.0.0.1:9180/apisix/admin/ssls/ssl_example \
  | jq '.value | {id, snis}'


8. Verifikasi HTTP dari host
Tes via HTTP plain (APISIX listen di port 80 dan 443 pada host):



# HTTP
curl -v "http://127.0.0.1/" -H "Host: sso.example.com"

# atau langsung ke IP server, misal 10.25.200.67
curl -v "http://10.25.200.67/" -H "Host: sso.example.com"
Respons yang diharapkan:

Status 302 Found

Header Location: https://sso.example.com/admin/

Header security dari APISIX (Strict-Transport-Security, dll.)

Contoh:

text

HTTP/1.1 302 Found
Location: https://sso.example.com/admin/
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Server: APISIX/3.8.0
9. Verifikasi HTTPS dan sertifikat
Dari host atau laptop (via DNS normal):



curl -vkI https://sso.example.com
Yang dicek:

TLS handshake OK, dengan cert:

subject: CN=*.example.com

masa berlaku sesuai sertifikat GlobalSign

HTTP status 302 dengan header Location: https://sso.example.com/admin/.

Kalau pakai curl -L, harus keluar HTML Keycloak Admin Console:



curl -L https://sso.example.com | head -n 30
Output awal harus seperti:

html

<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <base href="/resources/.../admin/keycloak.v2/">
    <title>Keycloak Administration Console</title>
    ...
10. Login ke Keycloak Admin
Buka browser di laptop/server (melalui VPN jika perlu):

text

https://sso.example.com/admin/
Login dengan:

Username: KC_ADMIN (default di .env: admin)

Password: KC_ADMIN_PASSWORD

Setelah masuk, lanjut konfigurasi realm, client, user, dsb sesuai kebutuhan.

11. Reset total (lab) dan konfigurasi ulang
Kalau ingin reset semuanya (lab):



cd ~/core-stack
docker compose down -v
docker compose up -d
Lalu ulangi urutan:

Section 5 – Siapkan AK

Section 6 – Buat upstream up_sso

Section 7 – Buat route route_sso

Section 8–9 – Verifikasi HS/HTTPS

Section 10 – Login Keycloak

12. Catatan penting
Semua nilai sensitif (password, admin key) diambil dari .env.
Di shell, cukup:



cd ~/core-stack
set -a
source .env
set +a
export AK="$APISIX_ADMIN_API_KEY"
Untuk production sesungguhnya:

Ganti semua password & key.

Batasi akses APISIX admin API dengan firewall dan/atau plugin ip-restriction (global rules).

Backup volume Postgres dan etcd secara berkala.

makefile


::contentReference[oaicite:0]{index=0}

