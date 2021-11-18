# Creating Expo Modules

## Components

- `name`

  Sets the name of the module that is exported to the JavaScript world.

- `constants`

  Definition function setting the module's constants to export.

- `function`

  Exports a native function to JavaScript. It supports up to 8 arguments (including `Promise` if needed).

- `viewManager`

  Creates the view manager definition that scopes other view-related definitions.

- `view`

  Defines the factory creating a native view when the module is used as a view.

- `prop`

  Creates a view prop that defines its name and setter.

- `events`

  Defines event names that this module can send to JavaScript.

- `onStartObserving`

  Function that is invoked when the first event listener is added.

- `onStopObserving`

  Function that is invoked when all event listeners are removed.

- `onCreate`

  Creates module's lifecycle listener that is called right after module initialization.

- `onDestroy`

  Creates module's lifecycle listener that is called when the module is about to be deallocated.

- `onAppContextDestroys`

  Creates module's lifecycle listener that is called when the app context owning the module is about to be deallocated.

- `onAppEntersForeground`

  Creates a listener that is called when the app is about to enter the foreground mode.

- `onAppBecomesActive` (iOS only)

  Creates a listener that is called when the app becomes active again.

- `onAppEntersBackground`

  Creates a listener that is called when the app enters the background mode.

## iOS App Delegate Subscribers

## Module config

- `platforms`

  An array of supported platforms.

- `ios`

  Config specific to iOS platform

  - `modulesClassNames`

    Names of Swift native modules classes to put to the generated modules provider file.

  - `appDelegateSubscribers`

    Names of Swift classes that hooks into `ExpoAppDelegate` to receive AppDelegate life-cycle events.

- `android`

  Config specific for Android platform

  - `modulesClassNames`

    Full names (package + class name) of Kotlin native modules classes to put to the generated package provider file.

https://blog.expo.dev/a-peek-into-the-upcoming-sweet-expo-module-api-6de6b9aca492
