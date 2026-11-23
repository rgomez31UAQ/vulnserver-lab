# Guía del participante — prueba de penetración autorizada

**Lee esto primero.** Vas a realizar una evaluación de seguridad autorizada sobre
un servidor de laboratorio que un compañero de clase desplegó para este
ejercicio. La autorización cubre *únicamente* esa máquina, *únicamente* durante la
ventana acordada y *únicamente* desde la red acordada. Cualquier otra cosa es
acceso no autorizado y queda fuera del alcance.

No debes:

- atacar ningún otro host, incluidos el hipervisor, la red de la escuela o
  internet;
- atacar el proyecto original de la imagen de Juice Shop ni su infraestructura;
- dejar persistencia, puertas traseras, mineros o cambios destructivos;
- modificar o borrar los logs de auditoría — el ejercicio los exige intactos;
- usar las flags o los reportes de otro estudiante.

Si dañas el host por accidente, detente y avísale de inmediato al propietario.

## 1. El objetivo

| Elemento | Valor |
|---|---|
| Host | tu compañero te dará la IP, por ejemplo `192.168.56.10` |
| Sistema operativo | Ubuntu Server 24.04 LTS |
| Aplicación web | OWASP Juice Shop, `http://<host>:3000` |
| SSH | `ssh labuser@<host>` (puerto 22), contraseña dada por el propietario |
| Alcance | toda la VM del laboratorio: app web, cuentas, permisos, sudo, cron |
| Ventana | acordada con el propietario; anuncia el inicio y el fin |

Recibes una cuenta **sin privilegios** (`labuser`). No tienes —y no debes
solicitar— la cuenta del propietario (`adminlab`).

## 2. Objetivos

Reúne y demuestra tres flags, en este orden:

| # | Ruta de la flag | Qué demuestra | Hasta dónde debes llegar |
|---|---|---|---|
| 1 | `/opt/vulnserver/flags/user.txt` | acceso inicial como `labuser` | iniciar sesión y leerla |
| 2 | `/opt/vulnserver/flags/privilege.txt` | nivel intermedio de privilegios | llegar a la cuenta delegada |
| 3 | `/opt/vulnserver/flags/root.txt` | compromiso total de root | ejecutar comandos como root |

Pistas de metodología (sin soluciones):

- enumera antes de explotar: usuarios, grupos, directorios home, derechos de
  sudo, rutas escribibles por todos, binarios SUID/SGID, tareas de cron,
  servicios y la aplicación web;
- la aplicación web es OWASP Juice Shop: sus propios retos son parte legítima del
  ejercicio, pero las flags viven en el sistema de archivos;
- el nivel intermedio existe porque el propietario delegó un conjunto acotado de
  tareas administrativas; estudia la delegación con cuidado;
- hay una tarea programada que forma parte del entorno; obsérvala antes de
  tocarla.

## 3. Reglas del ejercicio

1. Trabaja desde la red de origen acordada; no uses VPN, proxies ni shells en la
   nube que oculten tu origen.
2. Se permiten escáneres automatizados solo contra el host del laboratorio, con un
   límite de velocidad que no lo sobrecargue (Juice Shop con 2 vCPU).
3. No hagas fuerza bruta contra SSH más allá de una lista corta y dirigida de
   contraseñas; la contraseña del laboratorio ya te la dieron.
4. No instales paquetes en el host, no modifiques `/etc`, ni los permisos o
   ubicaciones de `/opt/vulnserver/logs` y `/opt/vulnserver/flags`, ni borres el
   volumen web.
5. Mantén tus herramientas en tu directorio home o en `/tmp`.
6. Detente cuando cierre la ventana. Reporta cualquier cosa que siga ejecutándose.

## 4. Flujo de trabajo sugerido

1. **Reconocimiento** — alcanzabilidad, puertos abiertos, versiones de servicios,
   cabeceras HTTP.
2. **Enumeración web** — Juice Shop es una aplicación de una sola página; explora
   su API y sus retos documentados.
3. **Enumeración del host** — `id`, `sudo -l`, `find / -perm -4000`, directorios
   escribibles, `/etc/cron*`, procesos en ejecución, sockets escuchando.
4. **Acceso inicial** — usa las credenciales de `labuser` que te dieron (SSH o la
   app web, si aplica). Registra el comando exacto y la marca de tiempo.
5. **Escalada de privilegios** — un paso a la vez; registra cada comando.
6. **Evidencia** — flags, transcripciones de comandos, marcas de tiempo,
   capturas de pantalla.
7. **Limpieza** — elimina solo los archivos que tú creaste.

## 5. Evidencia que debes entregar

Por cada flag:

- el valor de la flag (copiado y pegado, no reescrito a mano);
- el o los comandos que la produjeron, con marcas de tiempo;
- la identidad antes y después del paso (`id`, `whoami`);
- una captura de pantalla o de terminal por cada paso;
- el hallazgo al que corresponde y una valoración de severidad.

Entrega también:

- la lista de servicios y puertos que encontraste y por qué importa cada uno;
- todas las vulnerabilidades que identificaste, aunque no las hayas explotado;
- un párrafo por hallazgo sobre cómo debería corregirlo el propietario (no hace
  falta que apliques la corrección).

## 6. Plantilla de reporte

```markdown
# Evaluación de seguridad — VulnServer
Participante: <nombre>          Propietario/host: <nombre> / <IP>
Ventana: <inicio> – <fin>       Red de origen: <CIDR>

## 1. Resumen ejecutivo
<3–6 líneas: qué lograste, riesgo general, hallazgo más grave>

## 2. Alcance y metodología
Herramientas usadas, host de origen, restricciones, qué quedó excluido.

## 3. Hallazgos

### H-01 <título>
- Severidad: Crítica / Alta / Media / Baja
- Componente afectado: <servicio / archivo / cuenta>
- Evidencia: <salida de comando, referencia a captura>
- Impacto: <qué gana un atacante>
- Recomendación: <cambio de configuración preciso>
- Verificación: <cómo puede el propietario comprobar que está corregido>

(repite por cada hallazgo)

## 4. Evidencia de las flags

| Flag | Valor | Identidad | Comando | Marca de tiempo | Archivo de evidencia |
|---|---|---|---|---|---|
| USER | VS{...} | labuser | ... | ... | captura-01.png |
| PRIVILEGE | VS{...} | ... | ... | ... | captura-02.png |
| ROOT | VS{...} | root | ... | ... | captura-03.png |

## 5. Narrativa del ataque
Pasos numerados desde la primera conexión hasta root, cada uno con el comando usado.

## 6. Plan de remediación (priorizado)
1. <corrección de mayor impacto>
2. ...

## 7. Anexo
Transcripción completa de comandos, salida cruda de los escaneos, notas de limpieza.
```

## 7. Criterios de calificación (compartidos con el propietario)

| Criterio | Peso |
|---|---|
| Flag USER con evidencia válida | 20% |
| Flag PRIVILEGE alcanzada por la delegación prevista | 20% |
| Flag ROOT con pasos reproducibles | 25% |
| Calidad de los hallazgos y razonamiento de severidad | 15% |
| Recomendaciones de remediación | 15% |
| Profesionalismo (alcance, limpieza, claridad del reporte) | 5% |

Se otorga puntaje parcial por un hallazgo bien documentado que no pudiste
explotar. La evidencia fabricada califica con cero.

## 8. Después del ejercicio

El propietario endurecerá el servidor. Puede que te pidan repetir la evaluación:
en ese caso, documenta qué está bloqueado ahora y *por qué*, y confírmalo con los
mismos métodos. Si alguna ruta todavía funciona, eso es un hallazgo, no un fallo
tuyo.
