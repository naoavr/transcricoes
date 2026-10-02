#!/usr/bin/env bash
#
# instalar_transcricoes_v2.1.2.sh
#
# Instala a plataforma "Transcrição de Áudio" (v2.1.2) num servidor Debian/Ubuntu,
# sem intervenção: Apache + PHP (+curl, +mbstring, +sqlite3) + PHPMailer + plataforma
# + BACKOFFICE (/admin/, base de dados SQLite) + FILA ASSÍNCRONA de trabalhos + limites de upload (1 GB) + limpeza.
#
# Uso (como root):
#   bash instalar_transcricoes_v2.1.2.sh
#
# Opções por variáveis de ambiente (todas opcionais):
#   WHISPER_URL     URL do servidor Whisper          (predefinido: http://10.0.1.250:9000)
#   SMTP_HOST       Servidor SMTP                    (predefinido: mail.atena.3rhost.pt)
#   SMTP_PORT       Porta SMTP (SSL)                 (predefinido: 465)
#   SMTP_USER       Utilizador SMTP                  (predefinido: demo@atena.3rhost.pt)
#   SMTP_FROM       Remetente                        (predefinido: igual ao utilizador)
#   SMTP_PASSWORD   Palavra-passe SMTP               (predefinido: a do send-email.php incluído)
#   EMAIL_SUBJECT   Assunto do email
#   (WHISPER_URL, SMTP_* e EMAIL_SUBJECT só são aplicados se os indicares; depois disso
#    gerem-se no backoffice: /admin/ → Definições)
#   UPLOAD_MAX      Tamanho máximo de ficheiro       (predefinido: 1G)
#   POST_MAX        Tamanho máximo do pedido         (predefinido: 1100M)
#   WEB_ROOT        Pasta do site                    (predefinido: /var/www/html)
#   PHPMAILER_VERSION  Versão do PHPMailer a descarregar (predefinido: 7.0.2)
#   ADMIN_PASSWORD  Palavra-passe inicial do utilizador "admin" do backoffice (predefinido: gerada ao acaso)
#   DISABLE_INDEXES=no    não desligar a listagem de pastas do Apache
#   REMOVE_DIAG_FILES=no  não apagar phpinfo.php, info.php, debug_proxy.php, etc.
#
# Exemplo:
#   WHISPER_URL=http://10.0.1.250:9000 SMTP_PASSWORD='nova-palavra-passe' \
#       bash instalar_transcricoes_v2.1.2.sh
#
# Pode correr várias vezes (atualização): a base de dados e as definições do backoffice
# são mantidas; são feitas cópias de segurança antes de substituir ficheiros.
# Registo completo: /var/log/transcricoes-install.log
#
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2.1.2"
LOG_FILE="/var/log/transcricoes-install.log"
CONF_DIR="/etc/transcricoes"
CONF_FILE="$CONF_DIR/install.conf"

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi

case "${1:-}" in
  -h|--help)
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

step()  { echo; echo "${C_B}[$1] $2${C_0}"; }
info()  { echo "    $*"; }
ok()    { echo "    ${C_G}✔${C_0} $*"; }
warn()  { echo "    ${C_Y}⚠${C_0} $*"; WARNINGS=$((WARNINGS+1)); }
die()   { trap - ERR; echo "    ${C_R}✘ $*${C_0}" >&2; exit 1; }
WARNINGS=0

[ "$(id -u)" -eq 0 ] || die "Executa como root (ex.: sudo bash $0)"
command -v apt-get >/dev/null 2>&1 || die "Este instalador suporta Debian/Ubuntu (apt-get não encontrado)"

install -d -m 755 "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

TMPWORK="$(mktemp -d)"
trap 'rm -rf "$TMPWORK"' EXIT
trap 'die "Falhou na linha $LINENO (comando: $BASH_COMMAND). Ver $LOG_FILE"' ERR

echo "${C_B}=== Instalação da plataforma de transcrição v$SCRIPT_VERSION — $(date '+%Y-%m-%d %H:%M:%S') ===${C_0}"

# Variáveis indicadas explicitamente nesta execução (têm prioridade sobre o backoffice)
EXPLICIT=" "
for _k in WHISPER_URL SMTP_HOST SMTP_PORT SMTP_USER SMTP_FROM EMAIL_SUBJECT SMTP_PASSWORD; do
  if [ -n "${!_k+x}" ]; then EXPLICIT="$EXPLICIT$_k "; fi
done
is_explicit() { case "$EXPLICIT" in *" $1 "*) return 0;; *) return 1;; esac; }

# ── Configuração: ambiente > /etc/transcricoes/install.conf > predefinidos ──
load_conf() {
  local k v
  [ -r "$CONF_FILE" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      WEB_ROOT|WHISPER_URL|SMTP_HOST|SMTP_PORT|SMTP_USER|SMTP_FROM|EMAIL_SUBJECT|SMTP_PASSWORD|UPLOAD_MAX|POST_MAX)
        if [ -z "${!k+x}" ]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < "$CONF_FILE"
}
load_conf

: "${WEB_ROOT:=/var/www/html}"
: "${WHISPER_URL:=http://10.0.1.250:9000}"
: "${SMTP_HOST:=mail.atena.3rhost.pt}"
: "${SMTP_PORT:=465}"
: "${SMTP_USER:=demo@atena.3rhost.pt}"
: "${SMTP_FROM:=$SMTP_USER}"
: "${EMAIL_SUBJECT:=Resultado da Transcrição Whisper ASR}"
: "${SMTP_PASSWORD:=}"
: "${UPLOAD_MAX:=1G}"
: "${POST_MAX:=1100M}"
: "${PHPMAILER_VERSION:=7.0.2}"
: "${DISABLE_INDEXES:=yes}"
: "${REMOVE_DIAG_FILES:=yes}"

WHISPER_URL="${WHISPER_URL%/}"
case "$WHISPER_URL" in http://*|https://*) ;; *) die "WHISPER_URL inválido: $WHISPER_URL (tem de começar por http:// ou https://)";; esac
[[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || die "SMTP_PORT inválido: $SMTP_PORT"
[[ "$UPLOAD_MAX" =~ ^[0-9]+[KMG]$ ]] || die "UPLOAD_MAX inválido: $UPLOAD_MAX (ex.: 1G)"
[[ "$POST_MAX" =~ ^[0-9]+[KMG]$ ]] || die "POST_MAX inválido: $POST_MAX (ex.: 1100M)"

info "Pasta do site : $WEB_ROOT"
info "Whisper       : $WHISPER_URL (por defeito; depois gere-se no backoffice)"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

apt_install() {
  apt-get -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold -y --no-install-recommends install "$@"
}

# ── 1. Verificações ─────────────────────────────────────────
step "1/8" "Verificações prévias"
if command -v ss >/dev/null 2>&1; then
  port80_owner="$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2 || true)"
  if [ -n "$port80_owner" ] && [ "$port80_owner" != "apache2" ]; then
    die "A porta 80 está a ser usada por '$port80_owner'. Pára esse serviço ou usa outro servidor; o instalador não mexe em serviços que não conhece."
  fi
fi
ok "Porta 80 livre ou já ocupada pelo Apache"

tmp_free_mb="$(df -Pm /tmp | awk 'NR==2{print $4}')"
if [ "${tmp_free_mb:-0}" -lt 3072 ]; then
  warn "Só há ${tmp_free_mb} MB livres em /tmp; ficheiros de 1 GB precisam de pelo menos 1 GB livre (recomendado 3 GB)"
else
  ok "Espaço livre em /tmp: ${tmp_free_mb} MB"
fi

# ── 2. Pacotes ──────────────────────────────────────────────
step "2/8" "A instalar Apache, PHP e dependências (apt)"
apt-get -o Acquire::Retries=3 update -qq
apt_install apache2 php libapache2-mod-php php-curl php-mbstring php-sqlite3 sqlite3 curl ca-certificates tar gzip coreutils >/dev/null
ok "Pacotes instalados: $(apache2 -v | head -1 | sed 's/Server version: //'), PHP $(php -r 'echo PHP_VERSION;')"

# ── 3. Configuração do PHP ──────────────────────────────────
step "3/8" "Configuração do PHP (upload até $UPLOAD_MAX)"
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_APACHE_CONFD="/etc/php/$PHP_VER/apache2/conf.d"
[ -d "$PHP_APACHE_CONFD" ] || die "Não encontrei $PHP_APACHE_CONFD (libapache2-mod-php instalado?)"
phpenmod curl mbstring sqlite3 pdo_sqlite fileinfo 2>/dev/null || true
cat > "$PHP_APACHE_CONFD/99-transcricoes.ini" <<EOF
; gerado por instalar_transcricoes_v$SCRIPT_VERSION
upload_max_filesize = $UPLOAD_MAX
post_max_size = $POST_MAX
max_input_time = 3600
EOF
ok "$PHP_APACHE_CONFD/99-transcricoes.ini"

# ── 4. PHPMailer ────────────────────────────────────────────
step "4/8" "PHPMailer $PHPMAILER_VERSION"
install -d -m 755 "$WEB_ROOT" "$WEB_ROOT/phpmailer"
pm_dest="$WEB_ROOT/phpmailer"
if [ -f "$pm_dest/PHPMailer.php" ] && [ -f "$pm_dest/SMTP.php" ] && [ -f "$pm_dest/Exception.php" ] && [ "${PHPMAILER_UPDATE:-no}" != "yes" ]; then
  ok "Já presente ($(grep -o "VERSION = '[^']*'" "$pm_dest/PHPMailer.php" | head -1)) — mantido"
else
  pm_url="https://github.com/PHPMailer/PHPMailer/archive/refs/tags/v${PHPMAILER_VERSION}.tar.gz"
  pm_src=""
  if curl -fL --retry 3 --connect-timeout 15 -sS -o "$TMPWORK/pm.tgz" "$pm_url" && tar xzf "$TMPWORK/pm.tgz" -C "$TMPWORK"; then
    set -- "$TMPWORK"/PHPMailer-*/src
    if [ -f "$1/PHPMailer.php" ]; then pm_src="$1"; fi
  fi
  if [ -z "$pm_src" ]; then
    warn "Download do PHPMailer falhou; a usar o pacote libphp-phpmailer do sistema"
    apt_install libphp-phpmailer >/dev/null
    pm_file="$(find /usr/share -name PHPMailer.php -path '*hpmailer*' 2>/dev/null | head -1)"
    [ -n "$pm_file" ] || die "Não foi possível obter o PHPMailer (nem por download nem por apt)"
    pm_src="$(dirname "$pm_file")"
  fi
  for f in PHPMailer.php SMTP.php Exception.php; do
    [ -f "$pm_src/$f" ] || die "Ficheiro $f em falta no PHPMailer"
    install -m 644 "$pm_src/$f" "$pm_dest/$f"
  done
  ok "Instalado em $pm_dest ($(grep -o "VERSION = '[^']*'" "$pm_dest/PHPMailer.php" | head -1))"
fi

# ── 5. Plataforma, base de dados e backoffice ───────────────
step "5/8" "Plataforma, base de dados SQLite e backoffice"

# 5a. Extrair o pacote embutido neste script
marker="$(grep -n -a '^__PAYLOAD_BELOW__$' "$0" | tail -1 | cut -d: -f1)"
[ -n "$marker" ] || die "Pacote embutido não encontrado (o script foi alterado ou truncado?)"
mkdir -p "$TMPWORK/pkg"
tail -n +$((marker+1)) "$0" | tr -d '\r' | base64 -d | tar xz -C "$TMPWORK/pkg"
for f in web/index.php web/proxy.php web/cancel.php web/status.php web/send-email.php web/logo.php web/jobs.php web/result.php web/worker.php web/report.php opt/lib/queue.php \
         web/admin/index.php web/admin/admin.css web/admin/admin.js web/assets/js/app.js web/assets/css/styles.css \
         opt/lib/core.php opt/lib/admin.php opt/bin/admin.php opt/bin/seed.php; do
  [ -f "$TMPWORK/pkg/$f" ] || die "Pacote embutido incompleto (falta $f)"
done
for f in web/proxy.php web/cancel.php web/status.php web/send-email.php web/logo.php web/index.php web/admin/index.php web/jobs.php web/result.php web/worker.php web/report.php opt/lib/queue.php \
         opt/lib/core.php opt/lib/admin.php opt/bin/admin.php opt/bin/seed.php; do
  php -l "$TMPWORK/pkg/$f" >/dev/null || die "Erro de sintaxe PHP em $f"
done

# 5b. Cópia de segurança do que vai ser substituído/removido
DATA_DIR="/var/lib/transcricoes"
BACKUP_FILE=""
items=()
for f in index.html index.php proxy.php cancel.php status.php send-email.php logo.php jobs.php result.php worker.php report.php assets admin phpinfo.php info.php debug_proxy.php phpinfo.cgi perlinfo.pl; do
  if [ -e "$WEB_ROOT/$f" ]; then items+=("$f"); fi
done
if [ "${#items[@]}" -gt 0 ] || [ -d /opt/transcricoes ]; then
  install -d -m 700 /var/backups/transcricoes
  ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="/var/backups/transcricoes/pre-install-$ts.tgz"
  extra=()
  if [ -d /opt/transcricoes ]; then extra+=(-C / opt/transcricoes); fi
  if [ "${#items[@]}" -gt 0 ]; then tar czf "$BACKUP_FILE" -C "$WEB_ROOT" "${items[@]}" "${extra[@]}"; else tar czf "$BACKUP_FILE" "${extra[@]}"; fi
  chmod 600 "$BACKUP_FILE"
  ok "Cópia de segurança dos ficheiros existentes: $BACKUP_FILE"
  if [ -f "$DATA_DIR/transcricoes.db" ]; then
    sqlite3 "$DATA_DIR/transcricoes.db" ".backup '/var/backups/transcricoes/db-$ts.db'" && chmod 600 "/var/backups/transcricoes/db-$ts.db" \
      && ok "Cópia de segurança da base de dados: /var/backups/transcricoes/db-$ts.db" || warn "Não consegui copiar a base de dados existente"
  fi
fi

# 5c. Biblioteca (fora do webroot) e dados
install -d -m 755 /opt/transcricoes /opt/transcricoes/lib /opt/transcricoes/bin
install -m 644 "$TMPWORK"/pkg/opt/lib/*.php /opt/transcricoes/lib/
install -m 644 "$TMPWORK"/pkg/opt/bin/*.php /opt/transcricoes/bin/
install -d -m 750 -o www-data -g www-data "$DATA_DIR" "$DATA_DIR/brand" "$DATA_DIR/queue"
ok "Biblioteca em /opt/transcricoes · dados em $DATA_DIR"

# 5d. Base de dados: criar/migrar, importar definições antigas (v1.3), aplicar o que foi pedido
seed_args=()
if [ -f "$WEB_ROOT/send-email.php" ]; then seed_args+=("--import-send-email=$WEB_ROOT/send-email.php"); fi
if [ -f "$WEB_ROOT/proxy.php" ];      then seed_args+=("--import-proxy=$WEB_ROOT/proxy.php"); fi
seed_args+=("--default=whisper.url=$WHISPER_URL")
is_explicit WHISPER_URL   && seed_args+=("--set=whisper.url=$WHISPER_URL")
is_explicit SMTP_HOST     && seed_args+=("--set=smtp.host=$SMTP_HOST")
is_explicit SMTP_PORT     && seed_args+=("--set=smtp.port=$SMTP_PORT")
is_explicit SMTP_USER     && seed_args+=("--set=smtp.user=$SMTP_USER")
is_explicit SMTP_FROM     && seed_args+=("--set=smtp.from=$SMTP_FROM")
is_explicit EMAIL_SUBJECT && seed_args+=("--set=smtp.subject=$EMAIL_SUBJECT")
smtp_pw_env=""
if is_explicit SMTP_PASSWORD; then smtp_pw_env="$SMTP_PASSWORD"; fi
seed_out="$(runuser -u www-data -- env TR_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" TR_SET_SMTP_PASSWORD="$smtp_pw_env" \
            php /opt/transcricoes/bin/seed.php "${seed_args[@]}" --admin)" || die "Falhou a inicialização da base de dados SQLite"
# Cópia de reserva do endereço do Whisper (usada se a base de dados ficar inacessível)
cur_url="$(sqlite3 "$DATA_DIR/transcricoes.db" "select value from settings where key='whisper.url'" 2>/dev/null || true)"
[ -n "$cur_url" ] || cur_url="$WHISPER_URL"
U="$cur_url" php -r 'echo "<?php\nreturn " . var_export(["whisper.url" => getenv("U")], true) . ";\n";' > /opt/transcricoes/fallback.php
chmod 644 /opt/transcricoes/fallback.php
case "$seed_out" in *SEED_OK*) ok "Base de dados SQLite pronta ($DATA_DIR/transcricoes.db)";; *) die "Resposta inesperada da inicialização da base de dados";; esac
ADMIN_NEW_PW="$(printf '%s\n' "$seed_out" | sed -n 's/^ADMIN_CREATED:admin://p' | head -1)"
if [ -n "$ADMIN_NEW_PW" ]; then ok "Utilizador do backoffice criado: admin"; else ok "Utilizadores do backoffice já existentes — mantidos"; fi

# 5e. Ficheiros web
rm -rf "$WEB_ROOT/assets" "$WEB_ROOT/admin"
install -d -m 755 "$WEB_ROOT/assets/css" "$WEB_ROOT/assets/js" "$WEB_ROOT/admin"
install -m 644 "$TMPWORK/pkg/web/assets/css/styles.css" "$WEB_ROOT/assets/css/styles.css"
install -m 644 "$TMPWORK/pkg/web/assets/js/app.js"      "$WEB_ROOT/assets/js/app.js"
install -m 644 "$TMPWORK"/pkg/web/admin/* "$WEB_ROOT/admin/"
for f in index.php proxy.php cancel.php status.php send-email.php logo.php jobs.php result.php worker.php report.php; do
  install -m 644 "$TMPWORK/pkg/web/$f" "$WEB_ROOT/$f"
done
rm -f "$WEB_ROOT/index.html"   # o index.html teria precedência sobre o index.php
chown -R root:www-data "$WEB_ROOT/phpmailer" "$WEB_ROOT/assets" "$WEB_ROOT/admin" 2>/dev/null || true
ok "Plataforma instalada em $WEB_ROOT (frontoffice) e $WEB_ROOT/admin (backoffice)"

# 5f. Ficheiros de diagnóstico
if [ "$REMOVE_DIAG_FILES" = "yes" ]; then
  removed=""
  for f in phpinfo.php info.php debug_proxy.php phpinfo.cgi perlinfo.pl; do
    if [ -e "$WEB_ROOT/$f" ]; then rm -f "$WEB_ROOT/$f"; removed="$removed $f"; fi
  done
  if [ -n "$removed" ]; then ok "Ficheiros de diagnóstico removidos:$removed"; else ok "Sem ficheiros de diagnóstico a remover"; fi
fi

# 5g. Guardar definições da instalação
install -d -m 750 "$CONF_DIR"
{
  echo "# gerado por instalar_transcricoes_v$SCRIPT_VERSION em $(date -Is)"
  echo "# (as definições da plataforma — Whisper, SMTP, textos — estão na base de dados e gerem-se em /admin/)"
  for k in WEB_ROOT UPLOAD_MAX POST_MAX; do echo "$k=${!k}"; done
} > "$CONF_FILE"
chmod 600 "$CONF_FILE"

# ── 6. Extras ───────────────────────────────────────────────
step "6/8" "Apache"
if [ "$DISABLE_INDEXES" = "yes" ]; then
  cat > /etc/apache2/conf-available/transcricoes.conf <<EOF
# gerado por instalar_transcricoes_v$SCRIPT_VERSION
<Directory "$WEB_ROOT">
    Options -Indexes
</Directory>
EOF
  a2enconf transcricoes >/dev/null
  ok "Listagem de pastas desligada"
fi

# ── 7. Apache ───────────────────────────────────────────────
step "7/8" "A validar e (re)iniciar o Apache"
if ! cfg_out="$(apache2ctl configtest 2>&1)"; then
  echo "$cfg_out"
  die "Configuração do Apache inválida (ver acima)"
fi
ok "Configuração do Apache válida"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl enable apache2 >/dev/null 2>&1 || true
  systemctl restart apache2
else
  service apache2 restart || { apache2ctl -k restart 2>/dev/null || apache2ctl start; }
fi
sleep 2
ok "Apache em execução"

# ── 8. Testes ───────────────────────────────────────────────
step "8/8" "Testes de funcionamento"
http_code() { curl -s -o /dev/null -w '%{http_code}' -m 20 "$1" || echo 000; }
BASE="http://127.0.0.1"

if [ "$(http_code "$BASE/")" = "200" ]; then ok "Página inicial responde (200)"; else die "A página inicial não responde em $BASE/"; fi
if curl -s -m 20 "$BASE/" | grep -q 'TRANSCRICOES_CONFIG'; then ok "Frontoffice dinâmico (index.php) a ser servido"; else die "O frontoffice não está a ser servido por index.php"; fi
if [ "$(http_code "$BASE/assets/js/app.js")" = "200" ] && [ "$(http_code "$BASE/assets/css/styles.css")" = "200" ]; then ok "Ficheiros estáticos (JS/CSS) acessíveis"; else die "JS/CSS não acessíveis"; fi
if [ "$(http_code "$BASE/proxy.php")" = "405" ]; then ok "PHP a executar (proxy.php responde 405 a GET, como esperado)"; else die "proxy.php não devolveu 405: o Apache pode não estar a executar PHP"; fi
if [ "$(http_code "$BASE/worker.php")" = "403" ] && [ "$(http_code "$BASE/jobs.php")" = "400" ]; then ok "Fila: worker.php exige token (403) e jobs.php exige lote (400)"; else die "worker.php/jobs.php não respondem como esperado — a fila assíncrona não vai funcionar"; fi
if [ "$(http_code "$BASE/opt/transcricoes/lib/core.php")" = "404" ]; then ok "Código da biblioteca fora do alcance da web"; else warn "A biblioteca parece acessível por HTTP — verifica a configuração do Apache"; fi

probe="zz_probe_$$.php"
cat > "$WEB_ROOT/$probe" <<'EOF'
<?php echo ini_get('upload_max_filesize'), '|', ini_get('post_max_size'), '|',
 function_exists('curl_init') ? 'curl' : 'SEM-curl', '|', function_exists('mb_substr') ? 'mbstring' : 'SEM-mbstring', '|',
 extension_loaded('pdo_sqlite') ? 'sqlite' : 'SEM-sqlite', '|', class_exists('finfo') ? 'fileinfo' : 'SEM-fileinfo';
EOF
probe_out="$(curl -s -m 20 "$BASE/$probe" || true)"
rm -f "$WEB_ROOT/$probe"
IFS='|' read -r p_up p_post p_curl p_mb p_sq p_fi <<< "$probe_out"
if [ "$p_curl" = "curl" ] && [ "$p_mb" = "mbstring" ] && [ "$p_sq" = "sqlite" ] && [ "$p_fi" = "fileinfo" ]; then ok "Extensões PHP no Apache: curl, mbstring, sqlite, fileinfo"; else die "Extensões PHP em falta no Apache ($probe_out)"; fi
if [ "$p_up" = "$UPLOAD_MAX" ] && [ "$p_post" = "$POST_MAX" ]; then
  ok "Limites de upload ativos no Apache: upload_max_filesize=$p_up, post_max_size=$p_post"
else
  warn "Limites de upload diferentes do esperado no Apache (upload_max_filesize=$p_up, post_max_size=$p_post)"
fi

if [ "$DISABLE_INDEXES" = "yes" ]; then
  if [ "$(http_code "$BASE/assets/")" = "403" ]; then ok "Listagem de pastas desligada (403)"; else warn "A listagem de pastas ainda parece ativa em /assets/"; fi
fi

# Base de dados acessível pelo Apache (o logótipo/estado/definições dependem dela)
if [ -f "$DATA_DIR/transcricoes.db" ] && [ "$(stat -c %U "$DATA_DIR/transcricoes.db")" = "www-data" ]; then ok "Base de dados com o dono correto (www-data)"; else warn "A base de dados não pertence a www-data — o backoffice pode não conseguir gravar"; fi

st="$(curl -s -m 10 "$BASE/status.php" || true)"
case "$st" in
  *'"online"'*)  ok "Servidor Whisper acessível ($(sqlite3 "$DATA_DIR/transcricoes.db" "select value from settings where key='whisper.url'" 2>/dev/null || echo "$WHISPER_URL"))" ;;
  *'"busy"'*)    ok "Servidor Whisper acessível, mas ocupado a transcrever" ;;
  *'"offline"'*) warn "Servidor Whisper NÃO acessível a partir daqui — a plataforma fica instalada, mas só transcreve quando o Whisper estiver online (endereço em /admin/ → Definições)" ;;
  *)             warn "status.php devolveu uma resposta inesperada: $st" ;;
esac

# Backoffice: exige autenticação e aceita o login
adm_code="$(http_code "$BASE/admin/")"
if [ "$adm_code" = "302" ] || [ "$adm_code" = "200" ]; then ok "Backoffice acessível em /admin/ (pede autenticação)"; else die "O backoffice não responde em /admin/ (código $adm_code)"; fi
if [ -n "$ADMIN_NEW_PW" ]; then
  jar="$TMPWORK/cj.txt"
  csrf="$(curl -s -m 20 -c "$jar" "$BASE/admin/index.php?p=login" | grep -o 'name="csrf" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')"
  login_code="$(curl -s -m 20 -b "$jar" -c "$jar" -o /dev/null -w '%{http_code}' --data-urlencode "csrf=$csrf" --data-urlencode "username=admin" --data-urlencode "password=$ADMIN_NEW_PW" "$BASE/admin/index.php?p=login" || echo 000)"
  if [ "$login_code" = "302" ] && curl -s -m 20 -b "$jar" "$BASE/admin/index.php?p=dashboard" | grep -q 'Backoffice'; then ok "Login no backoffice testado com sucesso"; else warn "O teste de login no backoffice falhou (código $login_code) — usa: php /opt/transcricoes/bin/admin.php reset-password admin"; fi
fi

if command -v hostname >/dev/null 2>&1; then SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
echo
echo "${C_G}${C_B}Instalação concluída.${C_0}  Avisos: $WARNINGS"
echo "  Frontoffice       : http://${SERVER_IP:-<ip-do-servidor>}/"
echo "  Backoffice        : http://${SERVER_IP:-<ip-do-servidor>}/admin/"
if [ -n "$ADMIN_NEW_PW" ]; then
  echo "  Utilizador        : admin"
  echo "  Palavra-passe     : $ADMIN_NEW_PW   (guarda-a agora; altera-a em Utilizadores)"
fi
echo "  Ficheiros         : $WEB_ROOT   ·   biblioteca: /opt/transcricoes   ·   dados: $DATA_DIR"
echo "  Registo instalação: $LOG_FILE"
if [ -n "$BACKUP_FILE" ]; then echo "  Cópia de segurança: $BACKUP_FILE"; fi
echo "  Recuperar acesso  : php /opt/transcricoes/bin/admin.php reset-password admin"
exit 0
__PAYLOAD_BELOW__
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
+tle/wZCprPwABAEAA==
