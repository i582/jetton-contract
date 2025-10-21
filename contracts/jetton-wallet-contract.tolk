import "@stdlib/gas-payments"
import "errors"
import "jetton-utils"
import "messages"
import "fees-management"
import "storage"

type AllowedMessageToWallet =
    | AskToTransfer
    | AskToBurn
    | InternalTransferStep

type BounceOpToHandle = InternalTransferStep | BurnNotificationForMinter

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();

    val msg = lazy BounceOpToHandle.fromSlice(in.bouncedBody);
    val restoreAmount = match (msg) {
        InternalTransferStep => msg.jettonAmount,       // safe to fetch jettonAmount, because
        BurnNotificationForMinter => msg.jettonAmount,  // it's in the beginning of a message
    };

    var storage = lazy WalletStorage.load();
    storage.jettonBalance += restoreAmount;
    storage.save();
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToWallet.fromSlice(in.body);

    match (msg) {
        InternalTransferStep => {
            var storage = lazy WalletStorage.load();
            if (in.senderAddress != storage.minterAddress) {
                assert (in.senderAddress.isAddressOfJettonWallet(msg.transferInitiator, storage.minterAddress, contract.getCode())) throw ERR_INVALID_WALLET;
            }
            storage.jettonBalance += msg.jettonAmount;
            storage.save();

            var msgValue = in.valueCoins;
            var tonBalanceBeforeMsg = contract.getOriginalBalance() - msgValue;
            var storageFee = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);
            msgValue -= (storageFee + JETTON_WALLET_GAS_CONSUMPTION);

            if (msg.forwardTonAmount) {
                msgValue -= (msg.forwardTonAmount + in.originalForwardFee);

                val notifyOwnerMsg = createMessage({
                    bounce: false,      // we should not bounce here cause receiver can have uninitialized contract
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForRecipient {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        transferInitiator: msg.transferInitiator,
                        forwardPayload: msg.forwardPayload
                    }
                });
                notifyOwnerMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            if (msg.sendExcessesTo.isInternal() & (msgValue > 0)) {
                val excessesMsg = createMessage({
                    bounce: false,
                    dest: msg.sendExcessesTo,
                    value: msgValue,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId
                    }
                });
                excessesMsg.send(SEND_MODE_IGNORE_ERRORS);
            }
        }

        AskToTransfer => {
            assert (msg.forwardPayload.remainingBitsCount()) throw ERR_INVALID_PAYLOAD;
            assert (msg.transferRecipient.getWorkchain() == BASECHAIN) throw ERR_WRONG_WORKCHAIN;

            var storage = lazy WalletStorage.load();
            assert (in.senderAddress == storage.ownerAddress) throw ERR_NOT_FROM_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERR_NOT_ENOUGH_BALANCE;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            var forwardedMessagesCount = msg.forwardTonAmount ? 2 : 1;
            assert (in.valueCoins >
                msg.forwardTonAmount +
                // 3 messages: wal1->wal2,  wal2->owner, wal2->response
                // but last one is optional (it is ok if it fails)
                forwardedMessagesCount * in.originalForwardFee +
                (2 * JETTON_WALLET_GAS_CONSUMPTION + MIN_TONS_FOR_STORAGE)
            ) throw ERR_NOT_ENOUGH_TON;

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.transferRecipient, storage.minterAddress, contract.getCode()),
                value: 0,
                body: InternalTransferStep {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    transferInitiator: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                }
            });
            deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AskToBurn => {
            var storage = lazy WalletStorage.load();
            assert (in.senderAddress == storage.ownerAddress) throw ERR_NOT_FROM_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERR_NOT_ENOUGH_BALANCE;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            val notifyMinterMsg = createMessage({
                bounce: true,
                dest: storage.minterAddress,
                value: 0,
                body: BurnNotificationForMinter {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    burnInitiator: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                }
            });
            notifyMinterMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        else => {
            // ignore empty messages, "wrong opcode" for others
            assert (in.body.isEmpty()) throw 0xFFFF
        }
    }
}



get fun get_wallet_data(): JettonWalletDataReply {
    val storage = lazy WalletStorage.load();

    return {
        jettonBalance: storage.jettonBalance,
        ownerAddress: storage.ownerAddress,
        minterAddress: storage.minterAddress,
        jettonWalletCode: contract.getCode(),
    }
}

get fun get_balance(): coins {
    val storage = lazy WalletStorage.load();
    return storage.jettonBalance
}

// te6cckECCwEAAoQAART/APSkE/S88sgLAQIBYgIIA6jQ+JGONNMfMdcsILxqKMyW0z8x+gAwjhHXLCPe7L70kvI/4dM/MfoAMOLtRND6AAKgyAH6As7J7VTgINcsILxqKMzjAtcsIHxT9SzjAtcsIsr4PeQDBQcB/DHtRNAB0z/6APpA+kD6AAb6ACD6QPpAMPiSIccFkTCOOPiS+CooyM+EIM4TzskSXPkAAfkAWtdlAddlyM+MCATSyw/LD8v/y/9x+QQAAfpEWLoBwACw8uLD4lEmoMgB+gLOye1U+Jf4J28QIaGCCJiWgCAStgihggjk4cCgoQQAviKUN1tsIY4w+JNw+DojoKHIz5HNi0JyJ88LP1AG+gIUzhbOycjPhQgTzlAF+gJxzwtqzMlx+wAC4iDXLAUxI8IAsJJfA44XyM+FCM5Y+gKCENUydtvPC4rLP8ly+wDiAfwx0z/6APpA+kD0AfoAINdJ8uLEI/pEMMAA8uFN7UTQ+gAg+kD6QDD4kiLHBfLiwVM4vvLiwlE4ocgB+gISzsntVHJSQHHjBPiX+JNw+DoSqCWgggpiWgCgvPLixfgqyM+EIBfOEs7JyM+QXjUUZhjLP1AG+gIVzhLOAfoCEs4GAHLJyM+JiAFTI1z5AAH5AFrXZQHXZcjPjAgE0ssPyw/L/8v/cfkEAM8L/4EAjc8LdBLMEszMyYBA+wAAsI5NMe1E0PoAIPpA+kAw+JIixwXy4sEE0z/6APpAMFNRvvLiwlFRocgB+gIUzsntVMjPke92X3rLP1j6As7OycjPhYgSznHPC27MyYBQ+wDgMIQPAccA8vQCASAJCgAdv9gXaiaH0AfSB9IBh8FUABG/6T9qJofQAYTrRrQq
// te6cckECDAEAAoYAART/APSkE/S88sgLAQIBYgIJA7zQ+JGONNMfMdcsILxqKMyW0z8x+gAwjhHXLCPe7L70kvI/4dM/MfoAMOLtRND6AAKgyAH6As7J7VTgINcsILxqKMzjAtcsIHxT9SzjAtcsIsr4PeTjAjCEDwHHAPL0AwUIAfwx7UTQAdM/+gD6QPpA+gAG+gAg+kD6QDD4kiHHBZEwjjj4kvgqKMjPhCDOE87JElz5AAH5AFrXZQHXZcjPjAgE0ssPyw/L/8v/cfkEAAH6RFi6AcAAsPLiw+JRJqDIAfoCzsntVPiX+CdvECGhggiYloBmtgihggjk4cCgoSIEALyOMPiTcPg6I6ChyM+RzYtCcifPCz9QBvoCFM4WzsnIz4UIE85QBfoCcc8LaszJcfsAApQ3W2wh4iDXLAUxI8IAsI4XyM+FCM5Y+gKCENUydtvPC4rLP8ly+wCSXwPiAf4x0z/6APpA+kD0AfoAINdJ8uLEI/pEMMAA8uFN7UTQ+gAg+kD6QDD4kiLHBfLiwVM4vvLiwlE4ocgB+gISzsntVCNyceME+Jf4k3D4OhKoJaCCCmJaAKC88uLF+CrIz4QgF84SzsnIz5BeNRRmGMs/UAb6AhXOEs4B+gISzsnIBgFsic8WUyNc+QAB+QBa12UB12XIz4wIBNLLD8sPy//L/3H5BADPC/+BAI3PC3QSzBLMzMmAQPsABwAFYgBAAJox7UTQ+gAg+kD6QDD4kiLHBfLiwQTTP/oA+kAwU1G+8uLCUVGhyAH6AhTOye1UyM+R73Zfess/WPoCzs7JyM+FiBLOcc8LbszJgFD7AAIBIAoLAB2/2BdqJofQB9IH0gGHwVQAEb/pP2omh9ABhAGParE=
