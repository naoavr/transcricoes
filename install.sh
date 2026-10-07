#!/usr/bin/env bash
#
# instalar_transcricoes_v2.4.0.sh
#
# Instala a plataforma "Transcrição de Áudio" (v2.4.0) num servidor Debian/Ubuntu,
# sem intervenção: Apache + PHP (+curl, +mbstring, +sqlite3) + PHPMailer + plataforma
# + BACKOFFICE (/admin/, base de dados SQLite) + FILA ASSÍNCRONA de trabalhos + limites de upload (1 GB) + limpeza.
#
# Uso (como root):
#   bash instalar_transcricoes_v2.4.0.sh
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
#       bash instalar_transcricoes_v2.4.0.sh
#
# Pode correr várias vezes (atualização): a base de dados e as definições do backoffice
# são mantidas; são feitas cópias de segurança antes de substituir ficheiros.
# Registo completo: /var/log/transcricoes-install.log
#
# NOVIDADES-BEGIN
# Frontoffice: separadores estilo browser (Enviar · Em processamento · Resultados) com ícones e o separador ativo ligado ao painel.
# Grupo colorido «Transcrição» à volta dos separadores (nome em Textos e logótipo; liga/desliga em Definições → Formatação e interface).
# O resto mantém-se: cartão com tamanho fixo, botões sempre visíveis, descarga por ficheiro e fila assíncrona.
# NOVIDADES-END
#
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="2.4.0"
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
for f in web/index.php web/proxy.php web/cancel.php web/status.php web/send-email.php web/logo.php web/jobs.php web/result.php web/worker.php web/report.php opt/lib/queue.php opt/lib/update.php \
         web/admin/index.php web/admin/admin.css web/admin/admin.js web/assets/js/app.js web/assets/css/styles.css \
         opt/lib/core.php opt/lib/admin.php opt/bin/admin.php opt/bin/seed.php; do
  [ -f "$TMPWORK/pkg/$f" ] || die "Pacote embutido incompleto (falta $f)"
done
for f in web/proxy.php web/cancel.php web/status.php web/send-email.php web/logo.php web/index.php web/admin/index.php web/jobs.php web/result.php web/worker.php web/report.php opt/lib/queue.php opt/lib/update.php \
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
rwEAsAQA
