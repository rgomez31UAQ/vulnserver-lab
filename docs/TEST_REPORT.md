# Reporte de pruebas

Qué se **ejecutó realmente** para VulnServer v1.0, en qué entorno y qué falta por
verificar en una VM real. Nada en este documento es simulado: cada PASS de abajo
proviene de un comando cuya salida está guardada en
`reports/test-run-<marca-de-tiempo>.log`.

- Fecha de la corrida: 2026-11-23
- Resultado: **80 / 80 verificaciones funcionales PASS, 0 FAIL**
- Artefactos: `reports/test-matrix-20261123-120100.md`,
  `reports/test-run-20261123-120100.log`

## 1. Entorno usado para la validación

| Propiedad | Valor | Consecuencia |
|---|---|---|
| Host de compilación | Kali GNU/Linux Rolling, kernel 7.2.15 | los scripts son Bash portable, sin sintaxis exclusiva de Ubuntu más allá de las guardas de `apt`/`systemd` |
| Usuario | `kaliroot` (uid 1000), grupos que incluyen `sudo`, `docker` | Docker usable sin sudo; **sin sudo sin contraseña** |
| `sudo` | pide contraseña (no disponible) | no se pueden crear usuarios en el host ni tocar UFW/auditd/sshd del host |
| Docker | 28.5.2, cgroup v2, overlay2, Compose 2.40.3 | contenedores reales disponibles → pruebas de integración web y de laboratorio en sandbox |
| Recursos | 12 vCPU, 22.8 GiB de RAM, 693 GB libres | cómodo para pruebas y descargas de imágenes |
| `/dev/kvm` | presente pero inaccesible para el usuario (sin grupo `kvm`) | **no se pudo arrancar ninguna VM QEMU/KVM** aquí |
| systemd | en ejecución (PID 1) | existen los servicios del host, pero modificarlos requiere root |

### Qué significa esto

| Capa | ¿Validada aquí? | Cómo |
|---|---|---|
| Scripts Bash (sintaxis, lógica, manejo de errores) | **sí** | `bash -n` en cada script más ejecución completa |
| Creación de cuentas, permisos, política de sudo, cron | **sí** | ejecutado como root dentro de un contenedor desechable `ubuntu:24.04` |
| Las tres rutas de escalada de privilegios | **sí** | explotadas de principio a fin, flags leídas, root demostrado |
| Generación / propiedad / rotación de flags | **sí** | generadas, verificadas y rotadas por `reset-lab.sh` |
| Auditoría / hardening / reinicio / desinstalación | **sí** | ejecutados y sus efectos comprobados |
| Despliegue de Juice Shop | **sí** | `docker compose` en el host, HTTP 200 + health check |
| Arranque de VM Ubuntu, login por sshd, UFW, auditd, instalación del motor Docker | **no** | requiere root en una VM real de Ubuntu 24.04 |

El perfil de contenedor (`install.sh --profile container`) omite a propósito
Docker, UFW, auditd y sshd, porque no se pueden configurar desde un contenedor sin
privilegios en este host. La lógica del laboratorio sí se ejercita por completo.

## 2. Resultados por grupo

| Grupo | Verificaciones | PASS | FAIL |
|---|---|---|---|
| Dependencias de prueba | 2 | 2 | 0 |
| `install.sh --profile container` | 1 | 1 | 0 |
| Cuentas | 7 | 7 | 0 |
| Flags | 7 | 7 | 0 |
| Controles negativos (el laboratorio no está abierto de par en par) | 6 | 6 | 0 |
| Escenario A (permisos) | 8 | 8 | 0 |
| Escenario B (sudo) | 9 | 9 | 0 |
| Escenario C (cron) | 8 | 8 | 0 |
| Auditoría y reporte | 9 | 9 | 0 |
| Hardening | 10 | 10 | 0 |
| Reinicio | 6 | 6 | 0 |
| `lab-manager.sh` | 2 | 2 | 0 |
| Desinstalación (purge) | 5 | 5 | 0 |
| **Total** | **80** | **80** | **0** |

## 3. Evidencia de los comportamientos clave

**Instalación.** `install.sh --profile container --yes` termina con código 0 y
crea el árbol completo, tres cuentas, tres flags y la copia de las herramientas en
`/opt/vulnserver/bin`.

**Modelo de cuentas.**
- `adminlab` en `sudo`; `labuser` **no** está en `sudo`; el estado de contraseña de
  `labpriv` es `L`.
- Controles negativos: `labuser` no puede leer `root.txt` ni `privilege.txt`, no
  puede hacer `sudo` a root, no puede escribir en los directorios de logs ni de
  flags, pero **sí** puede leer `user.txt`.

**Escenario A.** Se aplica `chmod u+s /usr/bin/find` (`4755`) y se crea un punto
de restauración. Desde una sesión de `labuser`:

```
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \;
```

devuelve la flag ROOT (`uid=0` efectivo). `deactivate` restaura `0755` en el
binario y `0755` en el directorio.

**Escenario B.** Cadena de dos etapas demostrada:
1. `runuser -u labuser -- sudo -n -u labpriv /usr/bin/cat .../privilege.txt`
   devuelve la flag PRIVILEGE.
2. Como `labpriv`, reemplazar el ayudante de root escribible por el grupo
   (`/usr/local/bin/lab-healthcheck`, modo `774`, grupo `labpriv`) e invocar
   `sudo -n /usr/local/bin/lab-healthcheck` escribe `root.txt` en `/tmp` como root
   (archivo propiedad de `root`).

Después de `deactivate`, el archivo de sudoers desaparece, el ayudante queda
`root:root 0755` y `sudo -u labpriv cat /etc/shadow` es denegado.

**Escenario C.** El directorio escribible por todos es `0777`; una sesión de
`labuser` reemplaza el script de cron de root mediante renombrado. Una ejecución
real de cron (prueba habilitada con `RUN_CRON_TEST=1`) ejecuta el script del
atacante con **uid 0** y copia la flag ROOT. La desactivación elimina el drop-in y
restaura `0755` en el directorio.

**Auditoría.** `audit.sh --stdout` se ejecuta, produce un reporte con un resumen de
resultados y hallazgos por sección, detecta el firewall (ausente), valida los
permisos de las flags y deja el sistema de archivos sin cambios (sumas de
verificación idénticas antes y después).

**Reporte.** `report.sh --stdout` lista los eventos `SCENARIO_ACTIVATE`;
`events.log` es JSON válido por línea y registra al usuario que actúa.

**Hardening.** Con los tres escenarios reactivados, `harden.sh --apply --yes
--only permissions,sudo,suid,cron` quita el bit SUID, elimina el archivo de
sudoers delegado, asegura el ayudante, borra el drop-in de cron, restaura `0755`
en los directorios del laboratorio y escribe un directorio de respaldo. La ruta
SUID ya no entrega root, la auditoría posterior al hardening no reporta binarios
SUID inesperados y la copia de respaldo queda sin bits de privilegio.

**Reinicio.** Rota `user.txt` y `root.txt` (se comparan los valores), desactiva
todos los escenarios, conserva `backups/` y deja el directorio home del
participante solo con el esqueleto de la shell.

**Desinstalación.** `uninstall.sh --yes --purge` elimina `/opt/vulnserver`, los
archivos de sudoers y el drop-in de cron, y conserva `adminlab` como cuenta de
recuperación.

## 4. Integración de Juice Shop (Docker en el host)

Desplegada desde `web/docker-compose.yml` con un archivo de entorno de prueba
(`LAB_BIND_ADDR=127.0.0.1`, puerto 13000):

| Verificación | Resultado |
|---|---|
| `docker compose config` | válido |
| Imagen | `bkimminich/juice-shop:v17.1.1` (fijada) |
| `GET /` | **HTTP 200** |
| `GET /rest/admin/application-version` | `{"version":"17.1.1"}` |
| Salud del contenedor | **healthy** |
| `HostConfig.Memory` | `1073741824` (límite de 1 GiB aplicado) |
| `HostConfig.Privileged` | `false` |
| `SecurityOpt` | `no-new-privileges:true` |
| Rotación de logs | json-file, 10m × 3 |
| Desmontaje (`down -v`) | contenedor, red y volumen eliminados |

**Defecto encontrado y corregido:** el primer health check usaba `node` del
`PATH`, pero la imagen de Juice Shop no trae shell y mantiene Node en
`/nodejs/bin/node`, así que cada sondeo fallaba con
`executable file not found in $PATH` y el contenedor se quedaba en `starting`. El
health check ahora usa la ruta absoluta y el contenedor alcanza `healthy`.

## 5. Defectos encontrados durante la validación y corregidos

| # | Defecto | Síntoma | Corrección |
|---|---|---|---|
| 1 | el `useradd` de `labpriv` chocaba con el grupo ya creado | la instalación abortaba y no se creaban flags | crear el grupo primero y pasar `--gid` |
| 2 | `generate_flags.sh verify` interpretaba mal dueño/grupo/modo | la instalación terminaba con código distinto de cero en una instalación correcta | análisis de 4 campos, comparación de `dueño:grupo` y modo |
| 3 | `uninstall.sh --purge` recreaba el directorio de logs después de borrarlo | `/opt/vulnserver` sobrevivía a un purge | se desactiva el registro antes de eliminar el directorio de estado |
| 4 | el health check de Compose usaba `node` | el contenedor nunca llegaba a healthy | ruta absoluta `/nodejs/bin/node` |
| 5 | los respaldos de `harden.sh` conservaban el bit SUID | la copia SUID dentro de `backups/` era en sí una ruta de escalada | quitar los bits de privilegio de los respaldos; excluir el directorio de respaldos de los escaneos SUID |
| 6 | el arnés de pruebas pasaba con vacío contra vacío | falsos PASS ocultaban una instalación rota | una expectativa vacía ahora es un fallo |
| 7 | `lab-manager.sh status` abortaba cuando el contenedor no existía | `set -e`/`pipefail` mataba la asignación después de que `docker inspect` fallara | tolerar el fallo e imprimir `ausente` |

## 6. No validado aquí — debe ejecutarse en una VM real

| Verificación | Por qué no aquí | Cómo verificarlo en Ubuntu 24.04 |
|---|---|---|
| Arranque de la VM / cloud-init | sin acceso a KVM, sin VM | arranca la imagen y completa `INSTALLATION.md` |
| Login SSH por contraseña como `labuser`, login de root rechazado | sshd no instalable como usuario sin privilegios | `ssh labuser@host`, `ssh root@host` (debe fallar) |
| Reglas de UFW y política de denegar por omisión | requiere root + netfilter en el host | `sudo ./config/ufw/ufw-rules.sh apply; sudo ufw status verbose`; prueba desde un host fuera del alcance |
| Reglas de auditd cargadas en el kernel | subsistema de auditoría no disponible en el contenedor | `sudo ./scripts/monitoring/setup_audit.sh apply; sudo auditctl -l \| grep vulnserver` |
| Instalación de Docker con `--install-deps` | omitida por el perfil de contenedor | `sudo ./install.sh --install-deps` en una VM limpia |
| Integración con `systemctl` (ssh, cron, docker, auditd) | no hay systemd en el contenedor | `systemctl status ssh cron docker auditd` |
| Bloqueo del servicio de metadatos, firewall de la nube | sin VM en la nube | consulta `CLOUD_DEPLOYMENT.md` §8 |
| Ataques a nivel de kernel fuera del alcance | excluidos a propósito | no forman parte de este laboratorio |

## 7. Reproducir los resultados

```bash
# 1. Suite funcional en un contenedor desechable de Ubuntu 24.04 (necesita Docker)
RUN_CRON_TEST=1 ./tests/test-container.sh
cat "$(ls -t reports/test-matrix-*.md | head -1)"

# 2. Aplicación web en cualquier host con Docker
docker compose --env-file web/.env.example -f web/docker-compose.yml up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
docker inspect -f '{{.State.Health.Status}}' vulnserver-juice-shop
docker compose --env-file web/.env.example -f web/docker-compose.yml down -v

# 3. En una VM real (verificaciones manuales de §6)
sudo ./install.sh --install-deps --activate a,b,c
sudo ./lab-manager.sh status
sudo ./audit.sh
```

## 9. Acceso remoto con WireGuard

`scripts/remote/setup_remote_access.sh` se ejecutó de verdad dentro de un
contenedor `ubuntu:24.04` con `NET_ADMIN` y `wireguard-tools` instalado, así que
`wg0` era una interfaz real del kernel, no una simulación.

| Verificación | Resultado |
|---|---|
| `--apply` con dos pares | código 0; `wg show` lista `wg0`, puerto 51820, pares `10.8.0.2/32` y `10.8.0.3/32` |
| Dirección del servidor | `10.8.0.1/24` en `wg0` |
| Material de llaves | `wg0.conf`, `server.key`, `clients/*.conf`, `peers/*.info` todos en modo `600` |
| Segunda ejecución (idempotente) | pares existentes reportados, nuevo par agregado en la siguiente dirección libre, recarga con `wg syncconf` |
| `--remove-peer` con `--apply` | par eliminado de la interfaz, configuración de cliente borrada |
| Eliminar los últimos pares | rechazado con código 1; interfaz y configuración intactas |
| Cambio de endpoint | todas las configuraciones de cliente regeneradas con el nuevo endpoint |
| Simulación | imprime el plan, termina con 0, no escribe nada, no requiere root |
| Validación de entrada | rechaza `/16`, el puerto 99999 y un nombre de par con espacios |

Encontrado y corregido durante esta prueba: `wg-quick strip` rechazaba la
configuración temporal porque deriva el nombre de la interfaz del nombre del
archivo (ahora se valida como `<iface>.conf`), y `--apply --remove-peer` exigía
`--endpoint` otra vez por error (ahora se recuerda en
`/etc/wireguard/server.info`).

No verificado aquí: un handshake entre dos máquinas reales, el firewall del
proveedor, las reglas de UFW (no hay ufw en el contenedor),
`systemctl enable wg-quick@wg0` ni `--publish-web` (no hay laboratorio instalado en
el contenedor).

## 10. Aprovisionamiento en la nube y cloud-init (2026-11-23)

Probado en el mismo host (Kali Rolling, Docker 28.5.2). No se usó ninguna cuenta
de nube, credencial ni VM, así que esto valida la lógica de las herramientas, no
el comportamiento de los proveedores.

| Verificación | Resultado |
|---|---|
| `tests/test-cloud.sh` (mock de las API de Hetzner + Vultr) | **23/23 PASS**, código 0 |
| Creación en Hetzner | peticiones de imagen, plan, llave SSH, firewall y servidor emitidas con los cuerpos esperados |
| Firewall de Hetzner | `udp/51820` desde `0.0.0.0/0` y `tcp/22` solo desde el `/32` del operador |
| Creación en Vultr | `os_id` 24.04 x64, plan validado, `sshkey_id` + `firewall_group_id` adjuntos |
| Destrucción (ambos) | servidor/instancia y firewall eliminados, archivo de estado borrado, código 0 |
| Simulación | imprime el plan, no envía ninguna petición HTTP, no requiere token |
| Renderizado de cloud-init | YAML válido, ~2.5 KB, marcadores sustituidos, se rechaza lo que pase de 32 KiB, se rechazan `http://` y metacaracteres de shell |
| `bootstrap-vm.sh` en `ubuntu:24.04` (`--cap-add NET_ADMIN`) | `wg0` real en `10.8.0.1/24`, `install.sh --profile container` completado, marcador escrito, configuración de cliente en modo 0600 |
| Reejecución del bootstrap | idempotente: túnel y par existentes reutilizados, código 0 |

Defectos encontrados y corregidos mientras se escribía esto:

1. `api()` devolvía estado 1 cuando la respuesta no tenía cuerpo, así que cada
   `DELETE` exitoso se reportaba como fallido y `set -e` abortaba la destrucción.
2. Los cuerpos de petición de Vultr se construían con `jq --argjson` para IDs tipo
   `k1`/`g1`; jq terminaba con error y se enviaba un cuerpo vacío. Ahora los IDs
   se pasan con `--arg` y solo se convierten donde la API espera números.
3. `bootstrap-vm.sh` daba por hecho `iproute2`/`iptables`/`openssl`; una imagen
   mínima fallaba en `wg-quick`. Ahora se instalan junto con `wireguard-tools`.
4. Los comentarios propios de la plantilla de cloud-init eran sustituidos por el
   generador, corrompiendo el encabezado del archivo renderizado.
5. `install.sh` solo actualizaba `JUICE_SHOP_PORT` en el `.env` generado, así que
   una reejecución con `LAB_BIND_ADDR=10.8.0.1` seguía publicando en `0.0.0.0`.
   Ahora se reescribe la dirección de enlace y el sondeo de salud usa la dirección
   de enlace real.

No verificado aquí (requiere credenciales y una VM real):

- las respuestas reales de `POST /servers` / `POST /instances`, cuotas, nombres de
  imagen y plan, y precios al momento del despliegue;
- que el firewall del proveedor realmente descarte tráfico (el mock solo registra
  reglas);
- la ruta de subida por SSH y `bootstrap-vm.sh` contra una imagen real de nube con
  systemd, sshd, UFW, auditd y Docker;
- que cloud-init ejecute el user-data en el primer arranque, y la aceptación de
  los 32 KiB por parte de Hetzner (el tamaño se comprueba localmente);
- el `scp` de las configuraciones de cliente desde un servidor real
  (`fetch_clients`).

Reproducir:

```bash
./tests/test-cloud.sh

docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro ubuntu:24.04 bash -c '
  cp -a /src /work && cd /work
  LAB_DIR=/work PUBLIC_IP=203.0.113.10 PEER=owner \
  LAB_INSTALL_ARGS="--profile container --install-deps --yes" \
  ./scripts/cloud/bootstrap-vm.sh'
```

## 11. Integración continua y sitio del proyecto (2026-11-23)

Ambos corren en runners alojados en GitHub, sobre un repositorio público.

| Verificación | Resultado |
|---|---|
| Corrida de CI [45238307689](https://github.com/rgomez31UAQ/vulnserver-lab/actions/runs/45238307689) | success |
| `ci` → suite funcional (`RUN_CRON_TEST=1 ./tests/test-container.sh`) | `SUMMARY\|PASS=80\|FAIL=0` dentro del runner, 66 s |
| `ci` → herramientas de nube (`./tests/test-cloud.sh`) | 23/23 PASS |
| Despliegue de Pages [45238465319](https://github.com/rgomez31UAQ/vulnserver-lab/actions/runs/45238465319) | success; <https://rgomez31UAQ.github.io/vulnserver-lab/> devuelve 200, CSS 200 |
| `cloud-init/user-data.yaml` renderizado desde la URL del repositorio público | 1 950 bytes, YAML válido, la URL del tarball devuelve 200 |

La primera corrida de Pages falló: el workflow se disparó con el push que ocurrió
segundos antes de habilitar el sitio de Pages por la API, así que
`actions/configure-pages` recibió un 404. Volver a ejecutarlo después de habilitar
Pages funcionó; el fallo se deja visible en el historial de corridas en lugar de
borrarlo.

El sitio es estático y solo presenta el laboratorio — GitHub Pages no puede alojar
el servidor vulnerable, que sigue necesitando una VM con root, SSH, cron y Docker.

No verificado: un despliegue real en Hetzner (no había `HCLOUD_TOKEN`
disponible) y que cloud-init ejecute realmente este user-data en el primer
arranque.

## 12. Conclusión

La lógica del laboratorio — cuentas, flags, las tres rutas de escalada,
auditoría, hardening, reinicio y desinstalación — está verificada
funcionalmente en un espacio de usuario limpio de Ubuntu 24.04, incluida una
ejecución real de cron como root y dos compromisos completos de root. Los
componentes que requieren una máquina real con root (sshd, UFW, auditd,
instalación de Docker, arranque de la VM) están implementados y con la sintaxis
comprobada, pero quedan por confirmar en Ubuntu Server 24.04 siguiendo §6; aquí
no se declaran como verificados.
