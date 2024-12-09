// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Contrat {
    string public message;

    constructor(string memory _message) {
        message = _message;
    }

    function mettreAJourMessage(string memory _nouveauMessage) public {
        message = _nouveauMessage;
    }
}
