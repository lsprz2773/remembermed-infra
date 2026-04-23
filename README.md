# Infraestructura - RememberMed
Este repositorio contiene la configuración de infraestructura para desplegar localmente todo el ecosistema de **RememberMed** usando Docker.

## Resumen
Con un solo comando, este repositorio levanta los tres servicios necesarios para ejecutar la plataforma completa:
- **Base de datos** (PostgreSQL) — Con esquemas, vistas y datos iniciales.
- **API Backend** (Express + Prisma) — Clonada automáticamente desde su [repositorio](https://github.com/IsaacEspinoza0406/-backend-rememberme-d).
- **Frontend** (Next.js + React) — Clonado automáticamente desde su [repositorio](https://github.com/Moraaa4/Frontend-RememberMe-d).

## Prerrequisitos
- Tener instalado [Docker](https://www.docker.com/) y **Docker Compose**.
- Variables de entorno creadas en la raiz [Descarga](https://drive.google.com/drive/folders/1jYgbG86Udje6DTyyGGPxnkz8tUEdygiY?usp=sharing)

## Cómo levantar el proyecto

1. **Clonar este repositorio:**
   ```bash
   git clone https://github.com/lsprz2773/remembermed-infra.git
   cd remembermed-infra
   ```

2. **Configurar las variables de entorno:**
   ```bash
   cp .env.example .env
   ```

3. **Levantar todos los servicios:**
   ```bash
   docker compose up -d --build
   ```

4. **Acceder a la aplicación:**
   - Frontend: `http://localhost:3000`
   - API: `http://localhost:3005`
   - Base de datos: `localhost:5441`

## Estructura del repositorio
```
remembermed-infra/
├── Dockerfile.backend       # Clona y construye la API desde GitHub
├── Dockerfile.frontend      # Clona y construye el Frontend desde GitHub
├── docker-compose.yml       # Orquestador de los 3 servicios
├── database/                # Scripts SQL ejecutados al iniciar PostgreSQL
│   ├── 01_schema.sql        # Creación de tablas y esquemas
│   ├── 02_seed.sql          # Datos iniciales
│   └── 03_views.sql         # Vistas y funciones
├── .env.example             # Variables de entorno de ejemplo
├── .gitignore
└── README.md
```

## Comandos útiles
| Comando | Descripción |
|---|---|
| `docker compose up -d --build` | Levantar todo el ecosistema |
| `docker compose down` | Detener todos los servicios |
| `docker compose down -v` | Detener y eliminar volúmenes (resetea la BD) |
| `docker compose logs -f api` | Ver logs de la API en tiempo real |
| `docker compose logs -f frontend` | Ver logs del Frontend en tiempo real |
| `docker compose build --no-cache` | Reconstruir sin caché (forzar re-clone) |

## Repositorios relacionados
- [Frontend - RememberMed](https://github.com/Moraaa4/Frontend-RememberMe-d)
- [Backend - RememberMed](https://github.com/IsaacEspinoza0406/-backend-rememberme-d)
