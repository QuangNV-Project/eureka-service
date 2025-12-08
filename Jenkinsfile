pipeline {
    agent any

    tools {
        maven 'Maven'
        jdk 'JDK21'
    }

    environment {
        // Docker Hub credentials (configure in Jenkins Credentials)
        DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
        DOCKERHUB_IMAGE = 'quangnv1911/eureka-service'

        // GitHub credentials for Maven (configure in Jenkins)
        GITHUB_CREDENTIALS = credentials('github-credentials')

        // Dynamic variables
        IMAGE_TAG = ''
        SPRING_PROFILE = ''
        BRANCH_NAME = "${env.GIT_BRANCH.replaceFirst(/^origin\//, '')}"
        SHOULD_DEPLOY = 'false'

        // Maven
        MAVEN_OPTS = '-Xmx1024m'
        MAVEN_SETTINGS_FILE = '.m2/settings.xml'
        MAVEN_LOCAL_REPO = "${env.WORKSPACE}/.m2_cache/repository"

        // Job data
        JOB_NAME = "${env.JOB_NAME}"
        BUILD_NUMBER = "${env.BUILD_NUMBER}"
    }

    stages {
        // ================================================
        // 1️⃣ SETUP & DETERMINE ENVIRONMENT
        // ================================================
        stage('Setup Environment') {
            steps {
                script {
                    echo "Current branch: ${BRANCH_NAME}"

                    if (BRANCH_NAME == 'main') {
                        IMAGE_TAG = 'prod'
                        SPRING_PROFILE = 'prod'
                        SHOULD_DEPLOY = 'true'
                    } else if (BRANCH_NAME == 'dev') {
                        IMAGE_TAG = 'dev'
                        SPRING_PROFILE = 'dev'
                        SHOULD_DEPLOY = 'true'
                    }

                    env.IMAGE_TAG = IMAGE_TAG
                    env.SPRING_PROFILE = SPRING_PROFILE
                    env.SHOULD_DEPLOY = SHOULD_DEPLOY

                    echo "✅ Branch: ${BRANCH_NAME}"
                    echo "✅ Image Tag: ${IMAGE_TAG}"
                    echo "✅ Spring Profile: ${SPRING_PROFILE}"
                    echo "✅ Should Deploy: ${SHOULD_DEPLOY}"
                }
            }
        }

        // Cache maven
        stage('Restore Maven Cache') {
            steps {
                script {
                    echo "Restoring Maven cache (if available) from last successful build..."
                    try {
                        // requires Copy Artifact plugin; optional so pipeline continues if unavailable
                        copyArtifacts(projectName: env.JOB_NAME, selector: lastSuccessful(), filter: '.m2_cache/**', optional: true)
                        echo "✅ Maven cache restored (if present)"
                    } catch (err) {
                        echo "No previous cache available or copyArtifacts not configured: ${err}"
                    }
                }
            }
        }

        // ================================================
        // 2️⃣ PREPARE MAVEN SETTINGS
        // ================================================
        stage('Prepare Maven Settings') {
            steps {
                script {
                     configFileProvider([configFile(fileId: 'maven-settings', variable: 'MAVEN_SETTINGS_PATH')]) {
                         sh 'mkdir -p .m2'
                         sh "cp ${MAVEN_SETTINGS_PATH} ${MAVEN_SETTINGS_FILE}"
                         sh "mkdir -p ${MAVEN_LOCAL_REPO}"
                     }
                }
            }
        }

        // ================================================
        // 3️⃣ RUN BASIC TESTS (for non-dev/main branches)
        // ================================================
        stage('Run Tests') {
            when {
                expression { SHOULD_DEPLOY == 'false' }
            }
            steps {
                script {
                    echo "Running basic tests for branch: ${BRANCH_NAME}"

                    sh """
                        mvn -s ${MAVEN_SETTINGS_FILE} -Dmaven.repo.local=${MAVEN_LOCAL_REPO} clean test
                    """

                    echo "✅ Tests completed successfully"
                }
            }
        }

        // ================================================
        // 4️⃣ BUILD & PUSH DOCKER IMAGE (only for dev/main)
        // ================================================
        stage('Build Docker Image') {
            when {
                expression { SHOULD_DEPLOY == 'true' }
            }
            steps {
                script {
                    echo "Building Docker image..."

                    // try to pull previous images to use as cache
                    sh """
                        docker pull ${DOCKERHUB_IMAGE}:${IMAGE_TAG} || true
                        docker pull ${DOCKERHUB_IMAGE}:latest || true
                    """

                    // Build Docker image using cache-from to speed up builds
                    sh """
                        docker build \
                            --build-arg SPRING_PROFILE=${SPRING_PROFILE} \
                            --cache-from ${DOCKERHUB_IMAGE}:${IMAGE_TAG} \
                            --cache-from ${DOCKERHUB_IMAGE}:latest \
                            -t ${DOCKERHUB_IMAGE}:${IMAGE_TAG} .
                    """

                    echo "✅ Docker image built successfully"
                }
            }
        }

        stage('Push Docker Image') {
            when {
                expression { SHOULD_DEPLOY == 'true' }
            }
            steps {
                script {
                    echo "Pushing Docker image to Docker Hub..."

                    // Login to Docker Hub
                    sh """
                        echo ${DOCKERHUB_CREDENTIALS_PSW} | docker login -u ${DOCKERHUB_CREDENTIALS_USR} --password-stdin
                    """

                    // Push image
                    sh """
                        docker push ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                    """

                    echo "✅ Docker image pushed successfully"
                }
            }
        }

        // Save Maven cache for future builds
        stage('Save Maven Cache') {
            steps {
                script {
                    echo "Saving Maven cache for future builds..."
                    sh "mkdir -p ${env.WORKSPACE}/.m2_cache"
                    archiveArtifacts artifacts: '.m2_cache/**', onlyIfSuccessful: true, allowEmptyArchive: true
                    echo "✅ Maven cache archived (if present)"
                }
            }
        }

        // ================================================
        // 5️⃣ CLEANUP LOCAL IMAGES
        // ================================================
        stage('Cleanup Local Images') {
            when {
                expression { SHOULD_DEPLOY == 'true' }
            }
            steps {
                script {
                    echo "Cleaning up local Docker images..."
                    sh 'docker image prune -af || true'
                    echo "✅ Cleanup completed"
                }
            }
        }

        // ================================================
        // 6️⃣ DEPLOY TO SERVERS
        // ================================================
        // Deploy to DEV Server
        // ================================================
        stage('Deploy to DEV Server') {
            when {
                expression { BRANCH_NAME == 'dev' }
            }
            steps {
                script {
                    echo "🚀 Deploying to DEV Server..."

                    withCredentials([
                        string(credentialsId: 'remote-server-dev-host', variable: 'REMOTE_HOST'),
                        string(credentialsId: 'remote-server-dev-user', variable: 'REMOTE_USER'),
                        string(credentialsId: 'remote-server-dev-port', variable: 'REMOTE_PORT'),
                        sshUserPrivateKey(credentialsId: 'remote-ssh-key-dev', keyFileVariable: 'SSH_KEY')
                    ]) {
                        // Pull latest image
                        sh """
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                echo "Pulling latest image..."
                                docker pull ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        """

                        // Stop & remove old container
                        sh """
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                docker stop eureka-service || true
                                docker rm eureka-service || true
                            '
                        """

                        // Run new container
                        sh """
                            ssh -o StrictHostKeyChecking=no -i $SSH_KEY -p $REMOTE_PORT $REMOTE_USER@$REMOTE_HOST '
                                ENV_FILE=".env.dev"
                                PORT_VAR="EUREKA_SERVICE_PORT"
                                source ./infra/\${ENV_FILE}
                                eval "PORT=\\\$\${PORT_VAR}"

                                echo "Running on Server DEV -> Port: \$PORT"

                                docker run -d --name eureka-service --env-file ./infra/\$ENV_FILE --network dev-network -p \$PORT:\$PORT --restart unless-stopped ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        """

                        echo "✅ Deployed to DEV Server successfully"
                    }
                }
            }
        }

        // ================================================
        // Deploy to PROD Server
        // ================================================
        stage('Deploy to PROD Server') {
            when {
                expression { BRANCH_NAME == 'main' }
            }
            steps {
                script {
                    echo "🚀 Deploying to PROD Server..."

                    // Get SSH credentials from Jenkins
                    withCredentials([
                        string(credentialsId: 'remote-server-prod-host', variable: 'REMOTE_HOST'),
                        string(credentialsId: 'remote-server-prod-user', variable: 'REMOTE_USER'),
                        string(credentialsId: 'remote-server-prod-port', variable: 'REMOTE_PORT'),
                        sshUserPrivateKey(credentialsId: 'remote-ssh-key-prod', keyFileVariable: 'SSH_KEY')
                    ]) {
                        // Pull latest image
                        sh """
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                echo "Pulling latest image..."
                                docker pull ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        """

                        // Stop & remove old container
                        sh """
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                docker stop eureka-service || true
                                docker rm eureka-service || true
                            '
                        """

                        // Run new container
                        sh """
                            ssh -o StrictHostKeyChecking=no -i $SSH_KEY -p $REMOTE_PORT $REMOTE_USER@$REMOTE_HOST '
                                ENV_FILE=".env.prod"
                                PORT_VAR="EUREKA_SERVICE_PORT"
                                source ./infra/\${ENV_FILE}
                                eval "PORT=\\\$\${PORT_VAR}"

                                echo "Running on Server PROD -> Port: \$PORT"

                                docker run -d --name eureka-service --env-file ./infra/\$ENV_FILE --network prod-network -p \$PORT:\$PORT --restart unless-stopped ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        """

                        echo "✅ Deployed to PROD Server successfully"
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                echo "Pipeline execution completed"
            }
        }
        success {
            script {
                withCredentials([
                    string(credentialsId: 'telegram-bot-token', variable: 'TELEGRAM_BOT_TOKEN'),
                    string(credentialsId: 'telegram-chat-id', variable: 'TELEGRAM_CHAT_ID')
                ]) {
                    sh """
                        curl -s -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage \
                        -d chat_id=$TELEGRAM_CHAT_ID \
                        -d text="✅ Pipeline succeeded! Project: Eureka Service Job: $JOB_NAME (#$BUILD_NUMBER)"
                    """
                }
            }
        }

        failure {
            script {
                withCredentials([
                    string(credentialsId: 'telegram-bot-token', variable: 'TELEGRAM_BOT_TOKEN'),
                    string(credentialsId: 'telegram-chat-id', variable: 'TELEGRAM_CHAT_ID')
                ]) {
                    sh """
                        curl -s -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage \
                        -d chat_id=$TELEGRAM_CHAT_ID \
                        -d text="❌ Pipeline failed! Project: Eureka Service Job: $JOB_NAME (#$BUILD_NUMBER)"
                    """
                }
            }
        }
        cleanup {
            script {
                sh 'docker logout || true'
            }
        }
    }
}
