// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Mariage {
    address public conjoint1;
    address public conjoint2;
    string public dateMariage;
    string public temoins;
    bool public estMariageValide;

    event MariageCree(address conjoint1, address conjoint2, string dateMariage);
    event MariageAnnule(address conjoint1, address conjoint2);

    modifier seulementConjoints() {
        require(msg.sender == conjoint1 || msg.sender == conjoint2, "Seuls les conjoints peuvent executer cette action");
        _;
    }
        constructor(address _conjoint2, string memory _dateMariage, string memory _temoins) {
        conjoint1 = msg.sender;
        conjoint2 = _conjoint2;
        dateMariage = _dateMariage;
        temoins = _temoins;
        estMariageValide = true;

        emit MariageCree(conjoint1, conjoint2, dateMariage);
    }

    function annulerMariage() public seulementConjoints {
        estMariageValide = false;
        emit MariageAnnule(conjoint1, conjoint2);
    }

    function estToujoursValide() public view returns (bool) {
        return estMariageValide;
    }
}
"01/01/2024","Alice, Bob"