---
title: Creating Expo modules
---

<!-- import APISectionMethods from '../../components/plugins/api/APISectionMethods';
import ExpoModulesApi from './expo-modules-api.json';

<APISectionMethods header="Components" data={ExpoModulesApi} /> -->

## Definition components

### `name`

Sets the name of the module that JavaScript code will use to refer to the module. Takes string as an argument.

<details>
<summary>Usage</summary>

```swift
name("MyModuleName")
```

</details>

### `constants`

Sets constant properties on the module. Can take the dictionary or the closure that returns the dictionary.

<details>
<summary>Usage</summary>

<table>
<tr><td>Swift</td><td>Kotlin</td></tr>
<tr>
<td>

```swift
constants([
  "PI": 3.14159
])
```

</td>
<td>

```kotlin
constants(
  mapOf(
    "PI" to 3.14159
  )
)
```

</td>
</tr>
</table>

</details>

### `function`

Defines the native function that will be exported to JavaScript. Its `body` closure supports up to 8 arguments (including `Promise` for asynchronously resolved functions).

<details>
<summary>Usage</summary>

```swift
function("printMessage") { (message: String) in
  print(message)
}

function("asynchronouslyResolvedFunction") { (message: String, promise: Promise) in
  DispatchQueue.main.async {
    promise.resolve(message)
  }
}
```

</details>

### `viewManager`

Scopes the view manager definition consisting of other view-related definitions.

### `view`

Defines the factory creating a native view when the module is used as a view.

### `prop`

- **name**: `string` - Name of view prop that you want to define a setter.
- **setter**: `(view: ViewType, value: ValueType) -> ()` - Closure that is invoked when the view rerenders.

Defines a setter for the view prop of given name.

### `events`

- **events**: `string[]` - An array of event names.

Defines event names that the module can send to JavaScript.

### `onStartObserving`

Defines the function that is invoked when the first event listener is added.

### `onStopObserving`

Defines the function that is invoked when all event listeners are removed.

### `onCreate`

Defines module's lifecycle listener that is called right after module initialization. If you need to set up something when the module gets initialized, use this component instead of module's class initializer.

### `onDestroy`

Defines module's lifecycle listener that is called when the module is about to be deallocated. Use it instead of module's class destructor.

### `onAppContextDestroys`

Creates module's lifecycle listener that is called when the app context owning the module is about to be deallocated.

### `onAppEntersForeground`

Creates a listener that is called when the app is about to enter the foreground mode.

### `onAppBecomesActive`

Creates a listener that is called when the app becomes active again.

### `onAppEntersBackground`

Creates a listener that is called when the app enters the background mode.

## iOS AppDelegate subscribers

## Custom argument types

Records, CGFloat, CGPoint, CGRect, CGColor, UIColor

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

## Examples

https://blog.expo.dev/a-peek-into-the-upcoming-sweet-expo-module-api-6de6b9aca492
