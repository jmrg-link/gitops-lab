# 2. El chart de Helm

`charts/whoami` empaqueta la API para Kubernetes: un Deployment, un Service y un Job de migraciones.
Helm lo instala a mano en esta guía; en la siguiente, Argo CD lo instala desde Git.

## Qué genera

```bash
helm lint charts/whoami
helm template lab charts/whoami -n lab
```

| Recurso | Nombre | Qué hace |
|---|---|---|
| Job | `lab-whoami-migrate` | Corre antes de instalar o actualizar; en un proyecto real, `prisma migrate deploy` |
| Deployment | `lab-whoami` | 2 réplicas con rolling update sin pérdida de servicio |
| Service | `lab-whoami` | ClusterIP en el puerto 80; solo envía tráfico a los pods listos |

Los nombres salen de `whoami.fullname` en `_helpers.tpl`: `<release>-<chart>`, recortado a 63
caracteres, el límite de los nombres DNS en Kubernetes.

## Valores

`values.yaml` es la API pública del chart. Cada clave lleva su descripción en un comentario `# --`.

| Clave | Por defecto | Para qué |
|---|---|---|
| `replicaCount` | `2` | Con dos o más, un rolling update nunca deja la API sin servicio |
| `image.tag` | `""` | Vacío usa `appVersion` de `Chart.yaml` (`v1.11.0`); en GitOps lo cambia el CI |
| `rollingUpdate.maxSurge` | `1` | Pods de más durante un despliegue |
| `rollingUpdate.maxUnavailable` | `0` | Pods que pueden faltar; con `0` nunca baja de `replicaCount` |
| `resources` | 10m CPU, 16Mi / 64Mi | Request para reservar sitio en el nodo, límite de memoria contra fugas |
| `migrations.enabled` | `true` | Crea el Job de migraciones |

## Instalar, actualizar y volver atrás

```bash
kubectl config use-context docker-desktop
helm install lab charts/whoami -n lab --create-namespace --wait
kubectl -n lab get deploy,pods,svc,jobs
kubectl -n lab logs job/lab-whoami-migrate
```

En otra terminal, para llamar a la API:

```bash
kubectl -n lab port-forward svc/lab-whoami 8082:80
curl localhost:8082
```

Actualizar a otra versión y deshacerlo:

```bash
helm upgrade lab charts/whoami -n lab --set image.tag=v1.12.0 --wait --rollback-on-failure
helm history lab -n lab
helm rollback lab 1 -n lab --wait
```

En Helm 4, `--rollback-on-failure` sustituye al antiguo `--atomic`.

## Qué observar

**El Job va primero.** Las anotaciones `helm.sh/hook: pre-install,pre-upgrade` hacen que Helm lance la
migración y espere a que termine antes de tocar el Deployment. El log del Job dice para qué versión
migró.

**El rolling update.** Con `maxSurge: 1` y `maxUnavailable: 0`, Kubernetes crea un pod nuevo, espera
a que pase la readiness y solo entonces retira uno viejo. Se ve con `kubectl -n lab get pods -w`
durante el `upgrade`, o después en los eventos:

```bash
kubectl -n lab get events --field-selector involvedObject.kind=Deployment --sort-by=.lastTimestamp
```

**El apagado.** Un pod sale del Service a la vez que empieza a pararse. El `preStop` espera 5
segundos para que el Service deje de enviarle tráfico antes de que reciba SIGTERM. whoami no gestiona
SIGTERM y sale con error, así que el pod viejo aparece un instante como `Failed` antes de
desaparecer. Una API que cierra ordenadamente, como NestJS con `enableShutdownHooks()`, no lo haría.

**La versión de la aplicación.** `helm history` muestra `APP VERSION v1.11.0` también en la revisión
del `upgrade`: `--set image.tag` cambia la imagen, no el `appVersion` del chart. La versión real es la
que diga `image.tag`.

**El rollback no deshace la migración.** `helm rollback` crea una revisión nueva con el contenido de
la antigua, pero el Job solo es hook de `pre-install` y `pre-upgrade`: al volver atrás, el esquema se
queda como lo dejó la versión nueva. Por eso las migraciones se escriben en dos tiempos (*expand and
contract*): primero se añade lo nuevo sin romper lo viejo, y lo viejo se retira en un despliegue
posterior.

**El reparto entre réplicas.** El port-forward se engancha a un solo pod y se corta si ese pod se
sustituye. Para ver el reparto hay que preguntar desde dentro del clúster:

```bash
kubectl -n lab run probe --rm -it --image=busybox:1.38 --restart=Never -- \
  sh -c 'while true; do wget -qO- http://lab-whoami | grep Hostname; sleep 1; done'
```

## Limpiar

```bash
helm uninstall lab -n lab
kubectl delete namespace lab
```

`helm uninstall` no borra el Job, porque los recursos de un hook no forman parte de la release. Por
eso se borra el namespace entero.
