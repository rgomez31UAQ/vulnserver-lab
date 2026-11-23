# Despliegue en la nube

El laboratorio puede correr en una VM en la nube, pero una VM en la nube **no**
es un laboratorio privado. Esta guía cubre lo que realmente ofrece cada
proveedor (verificado en noviembre de 2026; los precios cambian), cómo mantener
el laboratorio fuera de internet y la configuración exacta de WireGuard.

> Los precios y las condiciones de las capas gratuitas se verificaron en las
> páginas de los proveedores y en reportes de 2026 al momento de escribir esto.
> Vuelve a comprobarlos antes de pagar. No supongas que una capa "gratuita" sigue
> vigente: Oracle redujo a la mitad su asignación gratuita de ARM en junio de
> 2026.

## 1. Comparación de proveedores (noviembre de 2026)

| Proveedor | Plan mínimo útil | Precio | Root / SSH | Ubuntu 24.04 | Red privada | Notas |
|---|---|---|---|---|---|---|
| **Oracle Cloud (Always Free)** | Ampere A1: 2 OCPU / 12 GB en total, o 2× AMD micro (1/8 OCPU, 1 GB) | 0 € mientras se mantenga dentro de Always Free | sí | sí (A1 y micro) | VCN + subred privada | requiere tarjeta; solo región principal; la capacidad A1 suele estar agotada; cuota recortada el 15 de junio de 2026 y aplicada desde ~18 de agosto de 2026; 200 GB de almacenamiento en bloque, 10 TB de salida al mes |
| **Oracle Cloud (PAYG / prueba)** | las mismas formas, 300 USD de crédito por 30 días | por uso después del crédito | sí | sí | sí | el crédito de prueba es independiente de Always Free |
| **Hetzner Cloud** | CX23: 2 vCPU / 4 GB / 40 GB NVMe | ≈ 5.99 €/mes con IPv4 (comprobado en octubre de 2026; los precios subieron el 15 de junio de 2026) | sí | sí | red privada (verifica la tarifa vigente) | facturación por hora con tope en el precio mensual; los planes CPX se agotan con frecuencia; ubicaciones en UE/EE. UU./Singapur |
| **DigitalOcean** | Basic 2 vCPU / 4 GB / 80 GB | 24 USD/mes (2 vCPU/2 GB 18 USD; 1 GB 6 USD) | sí | sí | VPC, gratis | facturación por segundo con tope mensual; producto de firewall sencillo |
| **Kamatera** | configurable 2 vCPU / 2–4 GB | por hora/mes, prueba de 30 días para cuentas nuevas | sí | sí | disponible | dimensionamiento fino, menos documentación comunitaria |

No recomendados para este laboratorio: hosting compartido, plataformas PaaS o de
aplicaciones (sin root, sin cron, sin SUID), capas gratuitas de "contenedores" o
cualquier proveedor cuyos términos prohíban alojar sistemas vulnerables.

### Qué significa realmente "gratis"

- **Oracle Always Free** es el único proveedor importante que mantiene una VM
  real gratis de forma indefinida, pero la caja ARM útil ahora es de 2 OCPU / 12
  GB (antes era 4/24 hasta el 15 de junio de 2026). Las instancias AMD micro (1 GB
  de RAM) son demasiado pequeñas en la práctica para Juice Shop más las
  herramientas del laboratorio; la forma A1 es la opción realista.
- Los recursos de Always Free deben estar en la **región principal** de la
  tenencia.
- ARM64 funciona: la imagen de Juice Shop es multiarquitectura y los scripts del
  laboratorio son neutrales respecto a la arquitectura. La ruta amd64 es la mejor
  probada.
- No hay virtualización anidada en estos planes: no puedes ejecutar QEMU/KVM
  *dentro* de la VM en la nube. La VM en la nube **es** el servidor del
  laboratorio.

## 2. Uso aceptable — lee esto antes de desplegar

Los hosts deliberadamente vulnerables son una fuente común de denuncias por
abuso. Antes de desplegar:

1. Lee la política de uso aceptable y de pruebas de seguridad del proveedor. La
   mayoría prohíbe el escaneo no autorizado y el tráfico abusivo; algunos exigen
   explícitamente que los sistemas vulnerables no sean alcanzables desde
   internet.
2. Asume que el laboratorio **nunca** debe ser alcanzable desde internet. No
   abras el puerto 3000 a `0.0.0.0/0`.
3. Prefiere una subred privada sin IP pública más un bastión/VPN. Si el proveedor
   exige una IP pública, restringe el firewall de la nube a tu propia dirección y
   al puerto de WireGuard.
4. Usa una cuenta o tenencia dedicada para el laboratorio, no tu cuenta de
   producción.
5. Destruye la instancia cuando termine el ejercicio. Toma una instantánea antes
   si la necesitas.

Si el proveedor no permite cargas vulnerables ni siquiera con firewall, ejecuta
el laboratorio en un hipervisor local. Eso es siempre la opción más segura por
omisión.

## 3. Topología de referencia

```
participante ──(WireGuard 10.8.0.0/24)──┐
                                        ├──> VM del laboratorio  (sin HTTP público)
propietario/admin ──(SSH por WireGuard)─┘        │
                                                 ├─ Juice Shop 127.0.0.1:3000 (o 10.8.0.1:3000)
                                                 └─ UFW: deniega toda entrada excepto wg0
```

- Solo `51820/udp` (WireGuard) está abierto a internet, idealmente restringido a
  direcciones de origen conocidas.
- SSH escucha solo en el túnel, o UFW permite SSH solo desde `10.8.0.0/24`.
- Juice Shop se publica en la interfaz del túnel, no en la NIC pública.

## 4. Crear la VM

### Oracle Cloud (Always Free)

1. Crea una VCN con una subred pública (para WireGuard) y una privada (para el
   laboratorio), o una sola subred con listas de seguridad estrictas.
2. Crea una instancia: forma `VM.Standard.A1.Flex`, 2 OCPU / 12 GB, imagen
   **Ubuntu 24.04**, volumen de arranque de 50 GB (el mínimo es de ~47 GB).
3. Entrada en la lista de seguridad / NSG: `51820/udp` desde tu dirección,
   `22/tcp` solo desde tu dirección. Ninguna otra entrada.
4. Guarda la llave SSH; conéctate como `ubuntu` y luego `sudo -i`.
5. Si la capacidad A1 no está disponible, reintenta en otro dominio de
   disponibilidad o pasa a Pay As You Go (los recursos de Always Free siguen
   gratis; lo que exceda se factura).

### Hetzner Cloud

1. New server → ubicación EU → imagen Ubuntu 24.04 → tipo CX23 (2 vCPU/4 GB).
2. Agrega tu llave SSH, sin volúmenes adicionales.
3. Firewall: entrada `22/tcp` y `51820/udp` solo desde tu IP.
4. Habilita los respaldos solo si aceptas el costo extra; una instantánea antes
   del ejercicio sale más barata.

### DigitalOcean

1. Create Droplet → Ubuntu 24.04 → Basic, 2 vCPU/4 GB (24 USD/mes).
2. Autenticación: solo llaves SSH.
3. Firewall en la nube: SSH de entrada desde tu IP, WireGuard UDP; todo lo demás
   denegado.
4. Toma una instantánea después de la instalación y destruye el Droplet al
   terminar.

### Si ya tienes una ISO de Ubuntu

**No la necesitas, y usarla empeora el despliegue.** Todos los proveedores de
arriba ofrecen una imagen oficial de Ubuntu 24.04 ya configurada para la nube:
DHCP, inyección de llaves SSH mediante cloud-init, consola serie y un volumen de
arranque que se ajusta al plan. Arrancar tu propia ISO significa no tener
cloud-init (y por lo tanto ni llaves SSH ni usuario), configuración manual de red
y una instalación interactiva de 30–60 minutos por una consola VNC.

La ISO tampoco aporta nada a este laboratorio: los scripts instalan todo lo demás
(`install.sh --install-deps`) y el laboratorio es un servidor Ubuntu normal.

Si aun así quieres tus propios medios, estas son las rutas verificadas
(comprobadas en noviembre de 2026):

| Proveedor | Medios personalizados | Formato | Notas |
|---|---|---|---|
| **Vultr** | sí | `.iso` por URL pública | máximo 10 GB, URL directa sin autenticación ni redirecciones, 2 ISO por cuenta, sin medios de Windows; arranca desde la ISO y luego usa la consola VNC |
| **Oracle Cloud** | solo importación | `.qcow2` o `.vmdk` | súbelo a Object Storage y luego *Compute → Custom Images → Import*; BIOS/MBR, un solo disco, sin cifrado, máximo 1 TB |
| **Hetzner Cloud** | solo biblioteca de ISO | imágenes del proveedor | la API de Cloud no permite subir imágenes; un disco personalizado requiere tomar una instantánea de un servidor existente o el procedimiento `.img` del sistema de rescate |
| **DigitalOcean** | imagen personalizada | `.qcow2`, `.vmdk`, `.raw` (verifica la lista vigente) | importación de imagen, no de ISO; el gestor de arranque ya debe estar instalado |

Sea cual sea la ruta, una vez que la máquina arranca estás en el mismo punto que
en §5: instalar WireGuard y Docker, clonar el repositorio y ejecutar
`install.sh`.

> Si instalas desde una ISO, crea tú mismo el usuario administrativo y copia tu
> llave pública SSH antes de exponer nada. Una VM en la nube con SSH solo por
> contraseña y una IP pública queda comprometida en cuestión de horas.

## 5. Instalar el laboratorio

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git wireguard

# Copia el proyecto a la VM (o clona tu fork):
sudo mkdir -p /root/vulnserver
sudo rsync -a --exclude reports/ --exclude .git/ ./ root@<vm>:/root/vulnserver/

# Crea el túnel PRIMERO (sección 6): la app web se enlaza a 10.8.0.1, que no
# existe hasta que wg0 está arriba, y Docker fallaría al publicar el puerto.
cd /root/vulnserver
sudo ./scripts/remote/setup_remote_access.sh --apply --endpoint <ip-publica> --peer owner

# Luego instala el laboratorio, publicando la app web solo en la dirección del túnel:
sudo LAB_BIND_ADDR=10.8.0.1 \
     SSH_ALLOWED_NETS="10.8.0.0/24" \
     LAB_ALLOWED_NETS="10.8.0.0/24" \
     ./install.sh --install-deps --activate a,b,c
```

Si instalas el laboratorio antes del túnel, vuelve a ejecutar
`setup_remote_access.sh --apply --publish-web` después para reenlazar Juice Shop.

Luego verifica desde la VM: `curl -s -o /dev/null -w '%{http_code}\n' http://10.8.0.1:3000/`.

### 5.1 Un solo comando (Hetzner o Vultr)

`scripts/cloud/provision.sh` hace las secciones 4–6 por ti: resuelve la imagen de
Ubuntu 24.04, registra tu llave SSH, crea un firewall, crea la VM, espera a SSH,
sube el proyecto por SSH, ejecuta `scripts/cloud/bootstrap-vm.sh` (primero el
túnel, después el laboratorio) y descarga las configuraciones de cliente de
WireGuard.

```bash
# Hetzner: Console -> Project -> Security -> API tokens (lectura/escritura)
export HCLOUD_TOKEN=...
./scripts/cloud/provision.sh --provider hetzner --name vulnserver-1

# Vultr: Account -> API -> Personal Access Token (todos los permisos)
export VULTR_API_KEY=...
./scripts/cloud/provision.sh --provider vultr --name vulnserver-1
```

Antes de crear nada puedes inspeccionar el plan sin credenciales:

```bash
./scripts/cloud/provision.sh --provider hetzner --name vulnserver-1 --dry-run
```

El firewall que crea permite **UDP 51820 desde cualquier lugar** y **TCP 22 solo
desde tu IP pública actual** (`--admin-cidr` la sobrescribe). Juice Shop y SSH
nunca se publican: ambos se alcanzan por el túnel en `10.8.0.1`.

La VM se factura desde su creación hasta su eliminación. El script nunca la
destruye en silencio, ni siquiera si el bootstrap falla, para que puedas leer el
log:

```bash
ssh root@<vm> tail -60 /var/log/vulnserver-bootstrap.log
./scripts/cloud/provision.sh --provider hetzner --name vulnserver-1 --destroy
```

El estado vive en `provision/<proveedor>-<nombre>.env` (modo 0600, ignorado por
git) y las llaves de cliente en `clients/` (ignorado por git). `--no-bootstrap`
se detiene cuando la VM ya está corriendo; `--user-data FILE` pasa cloud-init en
lugar de la subida por SSH.

### 5.2 Primer arranque desatendido con cloud-init

Si el proyecto es alcanzable por HTTPS al arrancar, la VM puede instalarse sola
sin subida por SSH. Genera el archivo user-data y pégalo en el formulario del
proveedor (Hetzner *Cloud config*, Vultr *Cloud-Init*, OCI *Initialization
script*):

```bash
./scripts/cloud/make-cloud-init.sh \
  --repo-url https://github.com/<tu-usuario>/vulnserver-lab/archive/refs/heads/main.tar.gz \
  --peer owner --out /tmp/vulnserver-user-data.yaml
```

Funciona tanto una URL `.tar.gz` como una URL de git. El archivo generado es
pequeño (unos 2.5 KB) porque descarga el proyecto al arrancar en lugar de
incrustarlo — Hetzner limita `user_data` a **32 768 bytes**, así que incrustar el
repositorio completo no es una opción. El script se niega a emitir un archivo
por encima de ese límite.

> **Un repositorio privado no sirve para cloud-init desatendido** a menos que la
> URL lleve un token de solo lectura, y ese token quedaría en los metadatos de la
> instancia, donde cualquier proceso de root (y el proveedor) puede leerlo. Para
> un repositorio privado usa `provision.sh` (subida por SSH) o clona por SSH
> después del primer arranque; deja cloud-init para repositorios públicos.

Después del primer arranque:

```bash
ssh root@<vm> tail -60 /var/log/vulnserver-bootstrap.log
scp root@<vm>:/etc/wireguard/clients/owner.conf .
# importa owner.conf, conéctate y luego http://10.8.0.1:3000/ y ssh labuser@10.8.0.1
```

Ten en cuenta que cloud-init solo se ejecuta una vez por instancia. Para volver a
ejecutar el bootstrap después de editar el repositorio, sube el proyecto de nuevo
con `scp` y ejecuta `sudo ./scripts/cloud/bootstrap-vm.sh`; todos los pasos son
idempotentes.

### 5.3 Publicar el proyecto en GitHub

El repositorio del laboratorio es seguro de alojar siempre que los artefactos de
ejecución queden fuera: `.gitignore` ya excluye `flags/`, `logs/`, `reports/`,
`backups/`, `provision/`, `clients/`, `cloud-init/user-data.yaml` y `*.iso`.
Comprueba antes del primer push:

```bash
git status --short
git ls-files | grep -E '(^|/)(flags|logs|reports|clients)/[^.]' || echo "limpio"
```

Nunca hagas commit de configuraciones de pares generadas, archivos `.env` ni los
valores de las flags del instructor. Un repositorio público te da la ruta de
cloud-init de arriba; uno privado (la opción más segura por omisión para un
laboratorio) necesita `provision.sh` o un token de solo lectura por repositorio.

## 6. Configuración del servidor WireGuard

### 6.1 Automatizada (recomendada)

`scripts/remote/setup_remote_access.sh` construye el túnel, las llaves, las
configuraciones de los pares y las reglas de firewall. Es idempotente: volver a
ejecutarlo conserva las llaves existentes y recarga la interfaz sin desconectar a
los clientes conectados.

```bash
# 1. Ver qué hará (sin root, sin cambios):
./scripts/remote/setup_remote_access.sh --endpoint 203.0.113.10 --peer owner

# 2. Aplicar en la VM:
sudo ./scripts/remote/setup_remote_access.sh \
     --apply --endpoint 203.0.113.10 --peer owner --peer alice

# 3. Publicar Juice Shop solo en el túnel y verificar:
sudo ./scripts/remote/setup_remote_access.sh --apply --publish-web
sudo ./scripts/remote/setup_remote_access.sh --status
```

Las copias de las configuraciones de cliente quedan en
`/etc/wireguard/clients/<peer>.conf` (modo `0600`); importa una en la aplicación
WireGuard de ese dispositivo, o agrega `--qr` para mostrar un código QR en un
teléfono (`apt install qrencode`).

Operaciones útiles:

```bash
sudo ./scripts/remote/setup_remote_access.sh --apply --peer tablet   # nuevo dispositivo
sudo ./scripts/remote/setup_remote_access.sh --apply --remove-peer tablet
sudo ./scripts/remote/setup_remote_access.sh --apply --endpoint nuevo.ejemplo.net
```

Cambiar el endpoint regenera todas las configuraciones de cliente; vuelve a
distribuirlas. El script se niega a eliminar el último par, lo que dejaría el
túnel inalcanzable.

**El orden importa:** `install.sh` aplica UFW con un reinicio de reglas.
Ejecútalo primero y después `setup_remote_access.sh`, o vuelve a ejecutar el
script de WireGuard después para restaurar `51820/udp` y la regla de permiso de
`wg0`. `config/ufw/ufw-rules.sh` también vuelve a agregar las reglas de WireGuard
cuando existe `/etc/wireguard/wg0.conf`.

### 6.2 Equivalente manual

```bash
cd /etc/wireguard
umask 077
wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee peer1.key | wg pubkey > peer1.pub
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <contenido de server.key>

# Laptop del propietario
[Peer]
PublicKey = <peer1.pub>
AllowedIPs = 10.8.0.2/32

# Laptop del participante
[Peer]
PublicKey = <participante.pub>
AllowedIPs = 10.8.0.3/32
```

```bash
systemctl enable --now wg-quick@wg0
wg show
```

Configuración del cliente (laptop del propietario):

```ini
[Interface]
Address = 10.8.0.2/32
PrivateKey = <peer1.key>
DNS = 1.1.1.1

[Peer]
PublicKey = <server.pub>
Endpoint = <ip-publica-de-la-vm>:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

Conéctate y luego `ssh adminlab@10.8.0.1` y `curl http://10.8.0.1:3000/`.

Dale a cada participante su propio par de llaves y elimina el bloque del par
cuando termine el ejercicio (`wg set wg0 peer <llave> remove`).

## 7. Firewall en la VM

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 51820/udp
sudo ufw allow in on wg0
sudo ufw --force enable
sudo ufw status verbose
```

`config/ufw/ufw-rules.sh` ya limita SSH y el puerto web a las redes
configuradas; para uso en la nube, configura esas redes como el túnel
(`10.8.0.0/24`).

El firewall del proveedor de nube es una segunda capa independiente: conserva
ambas. Abrir un puerto en UFW no lo abre en el firewall del proveedor, y
viceversa.

## 8. Riesgos específicos de la nube

| Riesgo | Mitigación |
|---|---|
| El escaneo de IP públicas encuentra Juice Shop | publica solo en `wg0` o en la dirección privada; el firewall de la nube deniega el 3000 |
| Servicio de metadatos de la nube (`169.254.169.254`) alcanzable desde una cuenta comprometida | bloquéalo para el usuario del laboratorio: `iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner labuser -j REJECT` (y para la red del contenedor) |
| El proveedor suspende la cuenta por abuso | mantén el laboratorio fuera de internet, usa una cuenta dedicada y destruye al terminar |
| Facturación con la instancia detenida | destruye, no detengas, cuando termines |
| Pérdida de evidencia con la instancia | copia `reports/` y `backups/` fuera del host antes de destruir |
| Túnel arriba pero sin handshake | el firewall del proveedor sigue bloqueando el puerto UDP; revisa el firewall de la nube **y** `ufw status` |
| El handshake funciona pero la página web no | Juice Shop está enlazado a `0.0.0.0` o a `127.0.0.1`; reenlaza con `--publish-web` y comprueba que `docker ps` muestre `10.8.0.1:3000` |
| El par no alcanza la VM después de un reinicio | `systemctl status wg-quick@wg0`; la interfaz debe subir antes de que Docker recree el contenedor |
| IP pública compartida con otros inquilinos | nunca escanees más allá de tu propia instancia |

Ejemplo de bloqueo de metadatos (agrégalo a la VM, no a los valores por omisión
del repositorio):

```bash
sudo iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner labuser -j REJECT
sudo iptables -I OUTPUT 1 -d 169.254.169.254 -s 172.28.60.0/24 -j REJECT
sudo netfilter-persistent save
```

## 9. Lista de verificación del control de costos

- [ ] la forma más pequeña que alcance (2 vCPU / 4 GB es suficiente)
- [ ] proveedor con facturación por hora si el laboratorio dura solo unos días
- [ ] instantánea en lugar de una segunda VM siempre encendida
- [ ] eliminar la instancia, los volúmenes y las IP reservadas al terminar el ejercicio
- [ ] revisar la factura después del primer ciclo, no antes

## 10. Cuándo no usar la nube

Elige un hipervisor local cuando:

- el proveedor prohíba hosts vulnerables o exija una IP pública;
- el ejercicio incluya ataques a nivel de kernel o de red;
- necesites instantáneas y rollback instantáneo;
- no puedas exponer las direcciones de origen de los participantes.

Una VM local con QEMU/KVM y una red host-only sigue siendo el mejor entorno para
este laboratorio.
