// This must be included before many other Windows headers.
#include <windows.h>

#include "bluetooth_low_energy_windows_plugin.h"

namespace bluetooth_low_energy_windows {
	// static
	void BluetoothLowEnergyWindowsPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
		auto messenger = registrar->messenger();
		auto central_manager = std::make_unique<MyCentralManager>(messenger);
		MyCentralManagerHostAPI::SetUp(messenger, central_manager.get());

		auto plugin = std::make_unique<BluetoothLowEnergyWindowsPlugin>(std::move(central_manager));
		registrar->AddPlugin(std::move(plugin));
	}

	BluetoothLowEnergyWindowsPlugin::BluetoothLowEnergyWindowsPlugin(std::unique_ptr<MyCentralManager> central_manager)
	{
		m_central_manager = std::move(central_manager);
	}

	BluetoothLowEnergyWindowsPlugin::~BluetoothLowEnergyWindowsPlugin() {}

}  // namespace bluetooth_low_energy_windows