// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Uncomment this line to use console.log
// import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "./Token.sol";
import "./MaintenanceReserve.sol";
import "./VacancyReserve.sol";

contract RentalProperties is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    address propertyManager;
    Token token;
    MaintenanceReserve maintenanceReserve;
    VacancyReserve vacancyReserve;
    bytes32 public whiteListRoot;

    struct rentalPropertyDetails {
        uint256 propertyTokenId;
        bool isOccupied;
        bool listed;
        uint256 rentalStartTimestamp;
        address tenant;
        uint256 propertyMaintenanceReserveCap;
        uint256 propertyVacancyReserveCap;
        uint256 currentRentalPeriodInDays;
        uint256 dailyRentAmountForThisRentalPeriod;
        uint256 rentCycleCounter;
    }
    // tokenId => rentalPropertyDetails
    mapping(uint256 => rentalPropertyDetails) rentalPropertyList;

    // tokenId => totalRemaining Rent for the current rental period
    mapping(uint256 => uint256) propertyRentDeposits;

    // tokenId => invvestorAddress => balance
    // mapping(uint256 => mapping(address => uint256)) shareHoldersRentIncomeBalances;

    event RentalPeriodInitiated(
        uint256 _rentalPropertyTokenId,
        address _tenantAddress,
        uint256 _rentalStartTimestamp,
        uint256 _rentPeriodInDays
    );
    event RentalPeriodTerminated(
        uint256 _rentalPropertyTokenId,
        address terminatedTenant,
        uint256 terminationTimestamp,
        uint256 returnedRemainingDepositAmount
    );
    event RentDistributed(
        uint256 _rentalPropertyTokenId,
        address[] _tokenOwnerList,
        uint256[] _rentAmountPerOwner
    );

    // event rentIncomeWithdrwal(
    //     uint256 _rentalPropertyTokenId,
    //     address beneficiaryAddr,
    //     uint256 withdrawalAmount
    // );

    function initialize(
        address _propertyTokenContract,
        address payable _maintenanceReserveContract,
        address payable _vacancyReserveContract,
        address _propertyManager
    ) external initializer {
        require(
            _propertyTokenContract != address(0),
            "Provide valid Property Token contract address"
        );
        require(
            _maintenanceReserveContract != address(0),
            "Provide valid Maintenance Reserve contract address"
        );
        require(
            _vacancyReserveContract != address(0),
            "Provide valid Vacancy Reserve contract address"
        );
        require(
            _propertyManager != address(0),
            "Provide valid Property Manager address"
        );
        __Ownable_init();
        token = Token(_propertyTokenContract);
        maintenanceReserve = MaintenanceReserve(_maintenanceReserveContract);
        vacancyReserve = VacancyReserve(_vacancyReserveContract);
        propertyManager = _propertyManager;
    }

    function setRoot(bytes32 _whiteListRoot) external onlyOwner {
        whiteListRoot = _whiteListRoot;
    }

    function isWhitelisted(bytes32[] memory proof, bytes32 leaf)
        public
        view
        returns (bool)
    {
        return MerkleProofUpgradeable.verify(proof, whiteListRoot, leaf);
    }

    function setPropertyManagerAddr(address _propertyManager)
        external
        onlyOwner
    {
        require(
            _propertyManager != address(0),
            "Provide valid Property Manager address"
        );
        propertyManager = _propertyManager;
    }

    modifier onlyPropertyManager() {
        require(
            msg.sender == propertyManager,
            "Caller is not the Property Manager"
        );
        _;
    }

    function enterRentalPropertyDetails(
        uint256 _propertyTokenId,
        uint256 _propertyMaintenanceReserveCap,
        uint256 _propertyVacancyReserveCap
    ) external onlyPropertyManager {
        require(
            token.exists(_propertyTokenId) == true,
            "Property with the given Token Id does not exist"
        );
        require(
            rentalPropertyList[_propertyTokenId].listed == false,
            "Property already registered for renting"
        );
        require(
            _propertyMaintenanceReserveCap > 0,
            "Property Maintenance Reserve should be more than zero"
        );
        require(
            _propertyVacancyReserveCap > 0,
            "Property Vacancy Reserve should be more than zero"
        );
        maintenanceReserve.setMaintenanceReserveCap(
            _propertyTokenId,
            _propertyMaintenanceReserveCap
        );
        vacancyReserve.setVacancyReserveCap(
            _propertyTokenId,
            _propertyMaintenanceReserveCap
        );
        rentalPropertyList[_propertyTokenId] = rentalPropertyDetails(
            _propertyTokenId,
            false,
            true,
            0,
            address(0),
            _propertyMaintenanceReserveCap,
            _propertyVacancyReserveCap,
            0,
            0,
            0
        );
    }

    function updateReserveCapAmount(
        uint256 _propertyTokenId,
        uint256 _newMaintenanceReserveCapAmount,
        uint256 _newVacancyReserveCapAmount
    ) external onlyPropertyManager {
        if (_newMaintenanceReserveCapAmount > 0) {
            rentalPropertyList[_propertyTokenId]
                .propertyMaintenanceReserveCap = _newMaintenanceReserveCapAmount;
            maintenanceReserve.setMaintenanceReserveCap(
                _propertyTokenId,
                _newMaintenanceReserveCapAmount
            );
        }
        if (_newVacancyReserveCapAmount > 0) {
            rentalPropertyList[_propertyTokenId]
                .propertyVacancyReserveCap = _newVacancyReserveCapAmount;
            vacancyReserve.setVacancyReserveCap(
                _propertyTokenId,
                _newVacancyReserveCapAmount
            );
        }
    }

    function initiateRentalPeriod(
        uint256 _propertyTokenId,
        address _tenant,
        uint256 _rentalPeriodInDays,
        uint256 _amountTowardsMaintenanceReserve,
        uint256 _amountTowardsVacancyReserve
    ) external payable onlyPropertyManager nonReentrant {
        require(
            rentalPropertyList[_propertyTokenId].listed == true,
            "Property is not listed for the rental period initiation"
        );
        require(
            rentalPropertyList[_propertyTokenId].isOccupied == false,
            "Property is already occupied"
        );
        require(_tenant != address(0), "Provide Valid Tenant address");
        require(
            msg.value > 0,
            "Please deposite rent for the whole month while initiating rental period"
        );
        uint256 remainingRentAmount = msg.value;
        uint256 maintenanceReserveDeficit;
        uint256 vacancyReserveDeficit;
        if (
            _amountTowardsMaintenanceReserve > 0 &&
            _amountTowardsMaintenanceReserve <= remainingRentAmount
        ) {
            (, , maintenanceReserveDeficit) = maintenanceReserve
                .checkMaintenanceReserve(_propertyTokenId);
            require(
                _amountTowardsMaintenanceReserve <= maintenanceReserveDeficit,
                "Please provide amount for the MaintenanceReserve less than or equal to its deficit"
            );
            maintenanceReserve.restoreMaintenanceReserve{
                value: _amountTowardsMaintenanceReserve
            }(_propertyTokenId);
            remainingRentAmount -= maintenanceReserveDeficit;
        }
        if (
            _amountTowardsVacancyReserve > 0 &&
            _amountTowardsVacancyReserve <= remainingRentAmount
        ) {
            (, , vacancyReserveDeficit) = vacancyReserve.checkVacancyReserve(
                _propertyTokenId
            );
            require(
                _amountTowardsVacancyReserve <= vacancyReserveDeficit,
                "Please provide amount for the VacancyReserve less than or equal to its deficit"
            );
            vacancyReserve.restoreVacancyReserve{
                value: _amountTowardsVacancyReserve
            }(_propertyTokenId);
            remainingRentAmount -= vacancyReserveDeficit;
        }
        uint256 _dailyRentAmountForThisRentalPeriod = remainingRentAmount /
            _rentalPeriodInDays;
        propertyRentDeposits[_propertyTokenId] += remainingRentAmount;
        rentalPropertyDetails
            storage _rentalPropertyDetails = rentalPropertyList[
                _propertyTokenId
            ];
        _rentalPropertyDetails.isOccupied = true;
        _rentalPropertyDetails.rentalStartTimestamp = block.timestamp;
        _rentalPropertyDetails.tenant = _tenant;
        _rentalPropertyDetails.currentRentalPeriodInDays = _rentalPeriodInDays;
        _rentalPropertyDetails
            .dailyRentAmountForThisRentalPeriod = _dailyRentAmountForThisRentalPeriod;
        _rentalPropertyDetails.rentCycleCounter = 0;
        assert(
            remainingRentAmount >=
                _dailyRentAmountForThisRentalPeriod * _rentalPeriodInDays
        );
        emit RentalPeriodInitiated(
            _propertyTokenId,
            _tenant,
            block.timestamp,
            _rentalPeriodInDays
        );
    }

    function terminateRentalPeriod(uint256 _propertyTokenId)
        public
        onlyPropertyManager
        nonReentrant
    {
        require(
            rentalPropertyList[_propertyTokenId].listed == true,
            "Property is not listed for the rental process"
        );
        require(
            rentalPropertyList[_propertyTokenId].isOccupied == true,
            "Property is already vacant"
        );
        uint256 remainingDepositAmount = propertyRentDeposits[_propertyTokenId];
        address _tenant = rentalPropertyList[_propertyTokenId].tenant;
        payable(_tenant).transfer(remainingDepositAmount);
        propertyRentDeposits[_propertyTokenId] = 0;
        rentalPropertyDetails
            storage _rentalPropertyDetails = rentalPropertyList[
                _propertyTokenId
            ];
        _rentalPropertyDetails.isOccupied = false;
        _rentalPropertyDetails.tenant = address(0);
        _rentalPropertyDetails.rentalStartTimestamp = 0;
        _rentalPropertyDetails.currentRentalPeriodInDays = 0;
        _rentalPropertyDetails.dailyRentAmountForThisRentalPeriod = 0;
        _rentalPropertyDetails.rentCycleCounter = 0;
        emit RentalPeriodTerminated(
            _propertyTokenId,
            _tenant,
            block.timestamp,
            remainingDepositAmount
        );
    }

    function distributeRentAmount(
        uint256 _propertyTokenId,
        address[] memory _ownerList
    ) external onlyPropertyManager nonReentrant {
        require(
            rentalPropertyList[_propertyTokenId].listed == true,
            "Property is not listed for the rental process"
        );
        require(
            rentalPropertyList[_propertyTokenId].isOccupied == true,
            "Property is not currently occupied"
        );
        require(
            rentalPropertyList[_propertyTokenId]
                .dailyRentAmountForThisRentalPeriod <=
                propertyRentDeposits[_propertyTokenId],
            "Not enough deposits to distribute the rent"
        );
        if (rentalPropertyList[_propertyTokenId].rentCycleCounter > 0) {
            require(
                rentalPropertyList[_propertyTokenId].rentalStartTimestamp +
                    (24 * 60 * 60) *
                    rentalPropertyList[_propertyTokenId].rentCycleCounter >=
                    block.timestamp,
                "Wait for the next rent distribution cycle"
            );
        }
        rentalPropertyList[_propertyTokenId].rentCycleCounter += 1;
        uint256 rentAmount = rentalPropertyList[_propertyTokenId]
            .dailyRentAmountForThisRentalPeriod;
        uint256 totalSupplyOfPropertyToken = token.totalSupply(
            _propertyTokenId
        );
        uint256 rentPerTokenShare = rentAmount / totalSupplyOfPropertyToken;
        uint256 balanceOfTheOwner;
        uint256[] memory rentAmountPerOwner;
        uint256 rentForAssert;
        for (uint256 i = 0; i < _ownerList.length; i++) {
            balanceOfTheOwner = token.balanceOf(
                _ownerList[i],
                _propertyTokenId
            );
            uint256 rentAmountForTheOwner = balanceOfTheOwner *
                rentPerTokenShare;
            rentAmountPerOwner[i] = rentAmountForTheOwner;
            rentForAssert += rentAmountForTheOwner;
        }
        assert(rentForAssert <= rentAmount);
        propertyRentDeposits[_propertyTokenId] -= rentForAssert;
        for (uint256 i; i < _ownerList.length; i++) {
            // shareHoldersRentIncomeBalances[_propertyTokenId][
            //     _ownerList[i]
            // ] += rentAmountPerOwner[i];
            payable(_ownerList[i]).transfer(rentAmountPerOwner[i]);
        }
        emit RentDistributed(_propertyTokenId, _ownerList, rentAmountPerOwner);
        if (
            rentalPropertyList[_propertyTokenId].rentCycleCounter ==
            rentalPropertyList[_propertyTokenId].currentRentalPeriodInDays
        ) {
            terminateRentalPeriod(_propertyTokenId);
        }
    }

    // function withdrawRentIncome(
    //     uint256 _propertyTokenId,
    //     bytes32[] memory proof
    // ) external nonReentrant {
    //     require(
    //         rentalPropertyList[_propertyTokenId].listed == true,
    //         "Property is not listed for the rental process"
    //     );
    //     require(
    //         isWhitelisted(proof, keccak256(abi.encodePacked(msg.sender))),
    //         "listProperty: Address not whitelisted"
    //     );
    //     require(
    //         shareHoldersRentIncomeBalances[_propertyTokenId][msg.sender] > 0,
    //         "Do not have any funds to withdraw"
    //     );
    //     uint256 amountToTransfer = shareHoldersRentIncomeBalances[
    //         _propertyTokenId
    //     ][msg.sender];
    //     shareHoldersRentIncomeBalances[_propertyTokenId][msg.sender] = 0;
    //     payable(msg.sender).transfer(amountToTransfer);
    //     emit rentIncomeWithdrwal(
    //         _propertyTokenId,
    //         msg.sender,
    //         amountToTransfer
    //     );
    // }
}
