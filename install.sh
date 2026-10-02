#!/usr/bin/env bash
#
# instalar_transcricoes_v2.1.1.sh
#
# Instala a plataforma "Transcrição de Áudio" (v2.1.1) num servidor Debian/Ubuntu,
# sem intervenção: Apache + PHP (+curl, +mbstring, +sqlite3) + PHPMailer + plataforma
# + BACKOFFICE (/admin/, base de dados SQLite) + FILA ASSÍNCRONA de trabalhos + limites de upload (1 GB) + limpeza.
#
# Uso (como root):
#   bash instalar_transcricoes_v2.1.1.sh
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
#       bash instalar_transcricoes_v2.1.1.sh
#
# Pode correr várias vezes (atualização): a base de dados e as definições do backoffice
# são mantidas; são feitas cópias de segurança antes de substituir ficheiros.
# Registo completo: /var/log/transcricoes-install.log
#
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2.1.1"
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
a3pNr+n1p7r+C7iRsEYAEAQA
