from lib.composegenerator.v0.networking import assignIp, configureMainNetworking
from lib.appvalidation.env import validateEnv
from lib.citadelutils import combineObjects
from lib.citadelconst import permissions
import os


# Main functions
def convertContainerPermissions(app):
    for container in app['containers']:
        if 'permissions' in container:
            for permission in container['permissions']:
                if(permission in permissions()):
                    container = combineObjects(
                        container, permissions()[permission])
                else:
                    print("Warning: container {} of app {} defines unknown permission {}".format(container['name'], app['metadata']['name'], permission))
            del container['permissions']
    return app

def convertContainersToServices(app: dict):
    app['services'] = {}
    for container in app['containers']:
        app['services'][container['name']] = container
        del app['services'][container['name']]['name']
    del app['containers']
    return app

# Converts the data of every container in app['containers'] to a volume, which is then added to the app
def convertDataDirToVolume(app: dict):
    for container in app['containers']:
        # Loop through data dirs in container['data'], if they don't contain a .., add them to container['volumes']
        # Also, a datadir shouldn't start with a /
        if 'data' in container:
            for dataDir in container['data']:
                if not 'volumes' in container:
                    container['volumes'] = []
                if(dataDir.find("..") == -1 and dataDir[0] != "/"):
                    container['volumes'].append(
                        '${APP_DATA_DIR}/' + dataDir)
                else:
                    print("Data dir " + dataDir +
                          " contains invalid characters")
            del container['data']
    return app



def convertIpToNetwork(app: dict, networkingFile: str, envFile: str):
    for container in app['containers']:
        if 'ip' in container:
            container['networks'] = {'default': {
                'ipv4_address': container['ip']}}
            del container['ip']
        elif 'assignip' in container:
            if(container['assignip'] != 'False'):
                container = assignIp(
                    container, app['metadata']['id'], networkingFile, envFile)
            del container['assignip']

    return app

def addStopConfig(app: dict):
    for container in app['containers']:
        if not 'stop_grace_period' in container:
            container['stop_grace_period'] = '1m'
        container['restart'] = "on-failure"
    return app


def convertToDockerComposeYML(app: dict, nodeRoot: str):
    if("version" in app):
        if(str(app['version']) != "0"):
            print("Warning: app version is not supported")
            return False
    envFile = os.path.join(nodeRoot, ".env")
    networkingFile = os.path.join(nodeRoot, "apps", "networking.json")

    app = convertContainerPermissions(app)
    validateEnv(app)
    app = convertDataDirToVolume(app)
    app = configureMainNetworking(app, nodeRoot)
    app = convertIpToNetwork(app, networkingFile, envFile)
    app = addStopConfig(app)
    app = convertContainersToServices(app)
    del app['metadata']
    if("version" in app):
        del app["version"]
    # Set version to 3.7 (current compose file version)
    app = {'version': '3.7', **app}
    return app
