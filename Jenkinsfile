pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }

    environment {
        DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
        DOCKERHUB_IMAGE = 'quangnv1911/eureka-service'
        BUILDX_BUILDER = 'eureka-service-builder'
    }

    stages {
        stage('Checkout') { steps { checkout scm } }

        stage('Resolve deployment context') {
            steps {
                script {
                    def branch = (env.BRANCH_NAME ?: env.GIT_BRANCH ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()).replaceFirst(/^origin\//, '')
                    if (!(branch in ['dev', 'main'])) {
                        echo "Branch ${branch} is outside the deployment scope."
                        return
                    }
                    def commit = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
                    if (!(commit ==~ /[0-9a-f]{12}/)) { error('Could not resolve a valid Git commit SHA') }
                    env.DEPLOY_BRANCH = branch
                    env.DEPLOY_ENV = branch == 'dev' ? 'dev' : 'prod'
                    env.REQUIRE_PROD_APPROVAL = (env.REQUIRE_PROD_APPROVAL ?: 'false').toBoolean().toString()
                    env.IMAGE_ALIAS = branch == 'dev' ? 'dev' : 'prod'
                    env.IMAGE_VERSION = "${env.BUILD_NUMBER}-${commit}"
                    env.IMAGE_REF = "${env.DOCKERHUB_IMAGE}:${env.IMAGE_VERSION}"
                    env.CACHE_REF = "${env.DOCKERHUB_IMAGE}:buildcache-${env.DEPLOY_ENV}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${branch} ${commit}"
                    echo "Deploy environment=${env.DEPLOY_ENV}, image=${env.IMAGE_REF}, requireProdApproval=${env.REQUIRE_PROD_APPROVAL}"
                }
            }
        }

        stage('Preflight Jenkins agent') {
            when { expression { env.DEPLOY_ENV in ['dev', 'prod'] } }
            steps {
                sh '''#!/usr/bin/env bash
                    set -Eeuo pipefail
                    docker version --format '{{.Server.Version}}'
                    docker buildx version
                    if ! docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1; then
                      docker buildx create --name "$BUILDX_BUILDER" --driver docker-container --use
                    else
                      docker buildx use "$BUILDX_BUILDER"
                    fi
                    docker buildx inspect --bootstrap
                '''
            }
        }

        stage('Registry login') {
            when { expression { env.DEPLOY_ENV in ['dev', 'prod'] } }
            steps {
                sh '''#!/usr/bin/env bash
                    set -Eeuo pipefail
                    printf '%s' "$DOCKERHUB_CREDENTIALS_PSW" | docker login -u "$DOCKERHUB_CREDENTIALS_USR" --password-stdin
                '''
            }
        }

        stage('Run DEV unit tests') {
            when { expression { env.DEPLOY_ENV == 'dev' } }
            steps {
                configFileProvider([configFile(fileId: 'maven-settings', variable: 'MAVEN_SETTINGS_PATH')]) {
                    sh '''#!/usr/bin/env bash
                        set -Eeuo pipefail
                        docker buildx build --builder "$BUILDX_BUILDER" --target test \
                          --secret id=maven_settings,src="$MAVEN_SETTINGS_PATH" \
                          --cache-from type=registry,ref="$CACHE_REF" \
                          --cache-to type=registry,ref="$CACHE_REF",mode=max .
                    '''
                }
            }
        }

        stage('Build and push immutable image') {
            when { expression { env.DEPLOY_ENV in ['dev', 'prod'] } }
            steps {
                configFileProvider([configFile(fileId: 'maven-settings', variable: 'MAVEN_SETTINGS_PATH')]) {
                    sh '''#!/usr/bin/env bash
                        set -Eeuo pipefail
                        docker buildx build --builder "$BUILDX_BUILDER" --target runtime \
                          --secret id=maven_settings,src="$MAVEN_SETTINGS_PATH" \
                          --cache-from type=registry,ref="$CACHE_REF" \
                          --cache-to type=registry,ref="$CACHE_REF",mode=max \
                          --tag "$IMAGE_REF" --push .
                    '''
                }
            }
        }

        stage('Approve production deployment') {
            when { expression { env.DEPLOY_ENV == 'prod' && env.REQUIRE_PROD_APPROVAL == 'true' } }
            steps {
                script {
                    timeout(time: 30, unit: 'MINUTES') {
                        input(
                            id: "eureka-service-prod-${env.BUILD_NUMBER}",
                            message: """
PRODUCTION RELEASE GATE

Service:       eureka-service
Environment:   PROD
Image:         ${env.IMAGE_REF}
Version:       ${env.IMAGE_VERSION}
Build:         #${env.BUILD_NUMBER}

Deployment policy (superseded by current behavior below):
  • Recreate one application instance
  • Readiness + Eureka registration gate
  • Two-minute stability soak
  • Automatic rollback to the previous immutable version on failure

Current behavior: deployment is committed immediately after the new container starts; health, Eureka, and soak checks are not executed, so they cannot trigger rollback.

Build details:
${env.BUILD_URL}
                            """.stripIndent().trim(),
                            ok: 'Deploy to PROD',
                            cancel: 'Abort release'
                        )
                    }
                }
            }
        }

        stage('Deploy') {
            when { expression { env.DEPLOY_ENV in ['dev', 'prod'] } }
            steps { script { deployService() } }
        }

        stage('Promote environment alias') {
            when { expression { env.DEPLOY_ENV in ['dev', 'prod'] } }
            steps {
                sh '''#!/usr/bin/env bash
                    set -Eeuo pipefail
                    docker buildx imagetools create --tag "$DOCKERHUB_IMAGE:$IMAGE_ALIAS" "$IMAGE_REF"
                '''
            }
        }
    }

    post {
        always {
            script {
                sendTelegram(
                    currentBuild.currentResult ?: 'UNKNOWN',
                    'See the Jenkins build for deployment details.'
                )
            }
        }
        cleanup {
            sh '''#!/usr/bin/env bash
                docker buildx prune --builder "$BUILDX_BUILDER" -f --filter until=168h || true
                docker logout || true
            '''
        }
    }
}

def deployService() {
    def config = env.DEPLOY_ENV == 'dev'
        ? [host: 'remote-server-dev-host', user: 'remote-server-dev-user', port: 'remote-server-dev-port', key: 'remote-ssh-key-dev', envFile: 'remote-server-dev-env-file', network: 'dev-network']
        : [host: 'remote-server-prod-host', user: 'remote-server-prod-user', port: 'remote-server-prod-port', key: 'remote-ssh-key-prod', envFile: 'remote-server-prod-env-file', network: 'prod-network']

    withCredentials([
        string(credentialsId: config.host, variable: 'REMOTE_HOST'),
        string(credentialsId: config.user, variable: 'REMOTE_USER'),
        string(credentialsId: config.port, variable: 'REMOTE_PORT'),
        string(credentialsId: config.envFile, variable: 'REMOTE_ENV_FILE'),
        sshUserPrivateKey(credentialsId: config.key, keyFileVariable: 'SSH_KEY')
    ]) {
        withEnv(["DOCKER_NETWORK=${config.network}"]) {
            sh '''#!/usr/bin/env bash
                set -Eeuo pipefail
                chmod 600 "$SSH_KEY"
                ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
                  -i "$SSH_KEY" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" \
                  "env DEPLOY_ENV='$DEPLOY_ENV' IMAGE_REF='$IMAGE_REF' IMAGE_VERSION='$IMAGE_VERSION' DOCKER_NETWORK='$DOCKER_NETWORK' REMOTE_ENV_FILE='$REMOTE_ENV_FILE' JENKINS_BUILD_NUMBER='$BUILD_NUMBER' bash -s" \
                  < infra/deploy.sh
            '''
        }
    }
}

def sendTelegram(status, details) {
    def statusIcon = [
        SUCCESS : '✅',
        FAILURE : '❌',
        UNSTABLE: '⚠️',
        ABORTED : '⏹️'
    ][status] ?: 'ℹ️'
    def escapeHtml = { value ->
        value.toString()
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
    }
    def message = """${statusIcon} <b>eureka-service deployment</b>

<b>Status:</b> <code>${escapeHtml(status)}</code>
<b>Build:</b> <code>#${escapeHtml(env.BUILD_NUMBER)}</code>
<b>Environment:</b> <code>${escapeHtml(env.DEPLOY_ENV ?: 'N/A')}</code>
<b>Version:</b> <code>${escapeHtml(env.IMAGE_VERSION ?: 'N/A')}</code>

${escapeHtml(details).replace('\n', '<br/>')}

🔗 <a href="${escapeHtml(env.BUILD_URL ?: '')}">Open Jenkins build</a>"""

    withCredentials([
        string(credentialsId: 'telegram-bot-token', variable: 'TELEGRAM_BOT_TOKEN'),
        string(credentialsId: 'telegram-chat-id', variable: 'TELEGRAM_CHAT_ID')
    ]) {
        withEnv(["TELEGRAM_MESSAGE=${message}"]) {
            sh '''#!/usr/bin/env bash
            set -Eeuo pipefail
            if ! curl -fsS -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
              -d "chat_id=$TELEGRAM_CHAT_ID" \
              -d 'parse_mode=HTML' \
              --data-urlencode "text=$TELEGRAM_MESSAGE"; then
              echo 'Telegram notification failed; pipeline result is unchanged.' >&2
            fi
            '''
        }
    }
}
