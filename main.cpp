#include <print>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <libvirt/libvirt.h>
#include <libvirt/libvirt-qemu.h>

#include "third_party/json.h"
#include "third_party/tinyxml2.cpp"


#define i8	int8_t
#define i16	int16_t
#define i32	int32_t
#define i64	int64_t

#define u8	uint8_t
#define u16	uint16_t
#define u32	uint32_t
#define u64	uint64_t

static constexpr std::string_view k_domainName =  "win11-24h2";
static constexpr std::string_view k_socketFormat = 
"/run/libvirt/qemu/channel/{}-{}/org.qemu.guest_agent.0";

int 
main(int argc, char **argv)
{
	if (auto pConnection = virConnectOpen("qemu:///system"
	); auto pDomain = virDomainLookupByName(
		pConnection, k_domainName.data()))
	{

		nlohmann::json guestExecCommand
		{
			{"execute", "guest-exec"},
			{"arguments", {
					{"path", "/bin/sh"},
					{"arg", {"-c", "id"}},
					{"capture-output", true}
			}}
		};
		std::string command = guestExecCommand.dump();
		char *reply = virDomainQemuAgentCommand(
				pDomain,
				command.c_str(),
				VIR_DOMAIN_QEMU_AGENT_COMMAND_DEFAULT,
				VIR_DOMAIN_QEMU_MONITOR_COMMAND_DEFAULT);
		auto err = virGetLastError();
		free(reply);
	}
	else
	{
		std::println(stderr,
				"Failed to connect domain {}",
				k_domainName);
	}
	return 0;
}
