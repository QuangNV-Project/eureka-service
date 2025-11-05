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

        // ================================================
        // 2️⃣ PREPARE MAVEN SETTINGS
        // ================================================
        stage('Prepare Maven Settings') {
            steps {
                script {
                     configFileProvider([configFile(fileId: 'maven-settings', variable: 'MAVEN_SETTINGS_PATH')]) {
                         sh 'mkdir -p .m2'
                         sh "cp ${MAVEN_SETTINGS_PATH} ${MAVEN_SETTINGS_FILE}"
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
                        mvn -s ${MAVEN_SETTINGS_FILE} clean test
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

                    // Build Docker image
                    sh """
                        docker build \
                            --build-arg SPRING_PROFILE=${SPRING_PROFILE} \
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

                    // Get SSH credentials from Jenkins
                    withCredentials([
                        string(credentialsId: 'remote-server-dev-host', variable: 'REMOTE_HOST'),
                        string(credentialsId: 'remote-server-dev-user', variable: 'REMOTE_USER'),
                        string(credentialsId: 'remote-server-dev-port', variable: 'REMOTE_PORT'),
                        sshUserPrivateKey(credentialsId: 'remote-ssh-key-dev', keyFileVariable: 'SSH_KEY')
                    ]) {
                        // Pull latest image
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                cd ./root_project
                                ENV_FILE=".env.dev"
                                echo "Branch: dev"
                                echo "ENV_FILE: \$ENV_FILE"
                                echo "Pulling latest image..."
                                docker pull ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        '''

                        // Stop & remove old container
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                docker stop eureka-service || true
                                docker rm eureka-service || true
                            '
                        '''

                        // Run new container
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                cd ./root_project
                                ENV_FILE=".env.dev"
                                PORT_VAR="EUREKA_SERVICE_PORT"
                                source ./infra/\$ENV_FILE
                                eval "PORT=\\$\$PORT_VAR"
                                echo "Running on Server A (dev) -> Port: \$PORT"
                                docker run -d --name eureka-service \\
                                    --env-file ./infra/\$ENV_FILE \\
                                    -p \$PORT:\$PORT \\
                                    ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        '''

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
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                cd ./root_project
                                ENV_FILE=".env.prod"
                                echo "Branch: main"
                                echo "ENV_FILE: \$ENV_FILE"
                                echo "Pulling latest image..."
                                docker pull ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        '''

                        // Stop & remove old container
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                docker stop eureka-service || true
                                docker rm eureka-service || true
                            '
                        '''

                        // Run new container
                        sh '''
                            ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} '
                                cd ./root_project
                                ENV_FILE=".env.prod"
                                PORT_VAR="EUREKA_SERVICE_PORT"
                                source ./infra/\$ENV_FILE
                                eval "PORT=\\$\$PORT_VAR"
                                echo "Running on Server B (main) -> Port: \$PORT"
                                docker run -d --name auth-service \\
                                    --env-file ./infra/\$ENV_FILE \\
                                    -p \$PORT:\$PORT \\
                                    ${DOCKERHUB_IMAGE}:${IMAGE_TAG}
                            '
                        '''

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
                echo "✅ Pipeline succeeded!"
            }
        }
        failure {
            script {
                echo "❌ Pipeline failed!"
            }
        }
        cleanup {
            script {
                // Logout from Docker Hub
                sh 'docker logout || true'
            }
        }
    }
}

