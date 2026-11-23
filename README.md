# VulnServer — Laboratorio de hardening y escalada de privilegios en Ubuntu v1.0

Un laboratorio reproducible sobre Ubuntu Server 24.04, deliberadamente
vulnerable, para un ejercicio universitario de **hardening de servidores**. Un
estudiante es dueño del servidor y lo endurece; un segundo estudiante autorizado
lo ataca; ambos documentan el resultado.

Sitio del proyecto: <https://rgomez31UAQ.github.io/vulnserver-lab/> (en español,
estático — GitHub Pages presenta el laboratorio, no puede alojar el servidor
vulnerable). Incluye una [demo en el navegador](site/demo/index.html) que simula
las cuentas, los permisos y los tres escenarios para practicar el flujo; es una
simulación en JavaScript, no una VM.

> **Solo para uso autorizado y aislado.** VulnServer crea un binario SUID de root,
> una política de sudo demasiado amplia y un cron de root que ejecuta un script
> escribible por el usuario. Cualquiera con acceso local puede convertirse en
> root. Ejecútalo únicamente en una VM desechable o en un host de laboratorio
> dedicado que nadie más use, y en una red privada.

| | |
|---|---|
| Sistema objetivo | Ubuntu Server 24.04 LTS (amd64; arm64 compatible) |
| Recursos del host | 2 vCPU, 2–4 GB de RAM, 20–25 GB de disco |
| Aplicación web | OWASP Juice Shop (imagen Docker fijada) |
| Escenarios | A: permisos de archivos · B: sudo · C: cron |
| Herramientas | Solo Bash (sin dependencia de runtime de Python) |
| Validación | 80/80 pruebas funcionales PASAN en un contenedor limpio de Ubuntu 24.04 |

## Cómo se ve el ejercicio

1. El propietario despliega el laboratorio (`install.sh`) y comparte el acceso con
   un compañero.
2. El compañero enumera el host y la aplicación web.
3. El compañero obtiene un punto de apoyo como `labuser` y lee la **flag USER**.
4. El compañero escala a la cuenta intermedia `labpriv` (Escenario B) y lee la
   **flag PRIVILEGE**.
5. El compañero obtiene root por cualquiera de los escenarios y lee la **flag
   ROOT**.
6. Ambos documentan la evidencia; el propietario aplica `harden.sh`.
7. El compañero repite el intento y demuestra que los caminos están cerrados.

## Inicio rápido

```bash
# En una VM desechable de Ubuntu Server 24.04, en una red aislada:
git clone <este-repo> vulnserver && cd vulnserver
sudo ./install.sh --install-deps --activate a,b,c

./lab-manager.sh            # estado / control de escenarios (interactivo)
sudo ./audit.sh             # reporte de hallazgos de solo lectura
sudo ./harden.sh --apply    # equivalente endurecido, con respaldos
```

Juice Shop se publica en el puerto **3000** por omisión y UFW la restringe a
`LAB_ALLOWED_NETS`. SSH permite únicamente a `adminlab` y `labuser`, nunca a
root.

## Estructura del repositorio

```
vulnserver/
├── install.sh                 # instalación completa (idempotente)
├── uninstall.sh               # instalación inversa, conserva evidencia por omisión
├── lab-manager.sh             # interfaz de administración en terminal
├── audit.sh                   # auditoría de solo lectura -> reports/audit-<ts>.md
├── harden.sh                  # respaldo + corrección + verificación
├── reset-lab.sh               # estado limpio, rota las flags
├── lib/common.sh              # registro, configuración, utilidades de seguridad
├── config/
│   ├── lab.conf               # todos los parámetros (sobrescribibles por entorno)
│   ├── ssh/99-vulnserver.conf # drop-in de sshd
│   ├── ufw/ufw-rules.sh       # firewall de aislamiento
│   └── scenarios/scenarios.conf
├── scripts/
│   ├── users/                 # creación de cuentas
│   ├── permissions/           # modelo base de permisos
│   ├── sudo/                  # política base de sudo
│   ├── cron/                  # base de cron
│   ├── scenarios/             # scenario-a.sh, scenario-b.sh, scenario-c.sh
│   ├── flags/                 # generación y verificación de flags
│   ├── monitoring/            # reglas de auditd, reporte de actividad
│   ├── remote/                # acceso WireGuard para VMs en la nube
│   └── cloud/                 # provision.sh (Hetzner/Vultr), arranque de VM, cloud-init
├── cloud-init/                # plantilla user-data para el primer arranque desatendido
├── web/docker-compose.yml     # OWASP Juice Shop
├── tests/                     # suite de pruebas funcionales en contenedor (+ mock de nube)
├── flags/ logs/ backups/ reports/   # en tiempo de ejecución (ignorados por git)
└── docs/                      # estudiante, administrador, hardening, nube, instructor
```

## Documentación

| Documento | Dirigido a |
|---|---|
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | propietario: desplegar en VM/host |
| [docs/ADMIN_GUIDE.md](docs/ADMIN_GUIDE.md) | propietario: operar, respaldar, restaurar |
| [docs/ATTACKER_GUIDE.md](docs/ATTACKER_GUIDE.md) | participante: alcance, objetivos, plantilla de reporte |
| [docs/HARDENING_GUIDE.md](docs/HARDENING_GUIDE.md) | propietario: corregir cada hallazgo, verificar |
| [docs/CLOUD_DEPLOYMENT.md](docs/CLOUD_DEPLOYMENT.md) | propietario: VM en la nube + WireGuard |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | todos |
| [docs/INSTRUCTOR_SOLUTIONS.md](docs/INSTRUCTOR_SOLUTIONS.md) | solo instructor: soluciones completas |
| [docs/TEST_REPORT.md](docs/TEST_REPORT.md) | instructor: qué se verificó realmente |

## Garantías de diseño

- **Aislamiento** — UFW con política de denegar por omisión; SSH y Juice Shop
  limitados a las redes configuradas; sin API de Docker en TCP; sin puertos de
  base de datos; sin panel de administración.
- **Reproducibilidad** — etiqueta de imagen fijada, scripts idempotentes, flags
  generadas al azar.
- **Auditabilidad** — bitácora de eventos en JSONL, registro de transcripción de
  sudo, reglas de auditd, integración con journald; los estudiantes no pueden
  escribir en el directorio de logs.
- **Reversibilidad** — cada escenario tiene `deactivate`; `harden.sh` respalda
  antes de cambiar nada; `reset-lab.sh` restaura la línea base y rota las flags.

## Licencia

MIT, con un aviso adicional que restringe el uso a laboratorios autorizados y
aislados. Consulta [LICENSE](LICENSE).
